defmodule UnreadHerring.Sunburst do
  @moduledoc """
  Pure geometry: turns an `UnreadHerring.Aggregate` tree plus a "current
  root" into SVG arc segments for a two-ring sunburst.

  No I/O, no processes.

  ## Angles

  0 rad is at 12 o'clock and angles increase clockwise. `point/4` maps an
  angle to SVG coordinates via `x = cx + r * sin(angle)`,
  `y = cy - r * cos(angle)`.

  ## Proportions

  Ring 1 spans are proportional to each child's count over the sum of the
  children's counts, so the ring always closes even when children do not
  sum to the parent (label grouping counts multi-label messages more than
  once). Ring 2 nests each child's children inside the parent's span,
  proportional to the grandchildren sum within that parent - ring 2 always
  fills the parent span exactly, so it shows proportions WITHIN the
  parent, not absolute shares of the whole.

  Each segment's `:share` is its count as a fraction of the current
  root's count.

  ## Full circles

  When a span covers the whole circle, `arc_path/6` emits a donut as two
  circle subpaths (outer drawn with two `A` half-circle commands, inner
  reversed); render with `fill-rule="evenodd"` so the hole stays open.

  ## Geometry constants

  Reused by the LiveView template: `view_box/0` (`"0 0 600 600"`),
  `center/0` (`{300, 300}`), `hole_radius/0` (88), `ring_width/0` (92).
  The 2-3 px gap between wedges is a stroke in the template, not part of
  the geometry here.
  """

  alias UnreadHerring.Aggregate

  @two_pi 2 * :math.pi()
  @full_circle_epsilon 1.0e-9

  @doc "SVG viewBox for the sunburst, `\"0 0 600 600\"`."
  def view_box, do: "0 0 600 600"

  @doc "Center of the sunburst as `{cx, cy}`."
  def center, do: {300, 300}

  @doc "Radius of the empty center hole (the zoom-out target)."
  def hole_radius, do: 88

  @doc "Radial width of each ring."
  def ring_width, do: 92

  @type segment :: %{
          node_id: String.t(),
          label: String.t(),
          count: non_neg_integer(),
          share: float(),
          depth: 1 | 2,
          start_angle: float(),
          end_angle: float(),
          r_inner: number(),
          r_outer: number(),
          color: String.t(),
          path_d: String.t(),
          has_children?: boolean()
        }

  @doc """
  Computes the list of segments for the sunburst rooted at
  `current_root_id`. `nil` or `"root"` means the tree root; an unknown id
  falls back to the tree root. Children with zero count produce no
  segments; a root with no (positive-count) children yields `[]`.
  """
  @spec segments(Aggregate.node_t(), String.t() | nil) :: [segment()]
  def segments(tree, current_root_id \\ nil) do
    root = resolve_root(tree, current_root_id)
    children = Enum.filter(root.children, &(&1.count > 0))
    children_sum = children |> Enum.map(& &1.count) |> Enum.sum()

    if children_sum == 0 do
      []
    else
      {cx, cy} = center()
      r0 = hole_radius()
      r1 = r0 + ring_width()
      r2 = r1 + ring_width()
      root_count = max(root.count, 1)

      {ring1, _} =
        Enum.map_reduce(children, 0, fn child, acc ->
          start_angle = @two_pi * acc / children_sum
          end_angle = @two_pi * (acc + child.count) / children_sum

          segment =
            build_segment(child, 1, start_angle, end_angle, r0, r1, root_count, cx, cy)

          {segment, acc + child.count}
        end)

      ring2 =
        Enum.flat_map(ring1, fn parent_segment ->
          parent = Enum.find(children, &(&1.id == parent_segment.node_id))
          grandchildren = Enum.filter(parent.children, &(&1.count > 0))
          grand_sum = grandchildren |> Enum.map(& &1.count) |> Enum.sum()

          if grand_sum == 0 do
            []
          else
            parent_span = parent_segment.end_angle - parent_segment.start_angle

            {segs, _} =
              Enum.map_reduce(grandchildren, 0, fn grandchild, acc ->
                start_angle = parent_segment.start_angle + parent_span * acc / grand_sum

                end_angle =
                  parent_segment.start_angle +
                    parent_span * (acc + grandchild.count) / grand_sum

                segment =
                  build_segment(grandchild, 2, start_angle, end_angle, r1, r2, root_count, cx, cy)

                {segment, acc + grandchild.count}
              end)

            segs
          end
        end)

      ring1 ++ ring2
    end
  end

  defp resolve_root(tree, nil), do: tree
  defp resolve_root(tree, "root"), do: tree
  defp resolve_root(tree, id), do: Aggregate.find_node(tree, id) || tree

  defp build_segment(node, depth, start_angle, end_angle, r_inner, r_outer, root_count, cx, cy) do
    %{
      node_id: node.id,
      label: node.label,
      count: node.count,
      share: node.count / root_count,
      depth: depth,
      start_angle: start_angle,
      end_angle: end_angle,
      r_inner: r_inner,
      r_outer: r_outer,
      color: color(node.label, depth),
      path_d: arc_path(cx, cy, r_inner, r_outer, start_angle, end_angle),
      has_children?: node.children != []
    }
  end

  @doc """
  SVG path `d` for an annulus sector between `start_angle` and
  `end_angle` (radians, 0 at 12 o'clock, clockwise).

  Normal case: move to inner start, line to outer start, clockwise outer
  arc (sweep 1) to outer end, line to inner end, counter-clockwise inner
  arc (sweep 0) back, `Z`; large-arc-flag is set when the span exceeds pi.

  Full-circle case (span >= 2*pi - epsilon): a donut made of two circle
  subpaths - the outer circle as two clockwise `A` half-arcs and the
  inner circle as two counter-clockwise `A` half-arcs - intended for
  `fill-rule="evenodd"`.
  """
  @spec arc_path(number(), number(), number(), number(), number(), number()) :: String.t()
  def arc_path(cx, cy, r_inner, r_outer, start_angle, end_angle) do
    if end_angle - start_angle >= @two_pi - @full_circle_epsilon do
      donut_path(cx, cy, r_inner, r_outer)
    else
      large = if end_angle - start_angle > :math.pi(), do: 1, else: 0
      {x1, y1} = point(cx, cy, r_inner, start_angle)
      {x2, y2} = point(cx, cy, r_outer, start_angle)
      {x3, y3} = point(cx, cy, r_outer, end_angle)
      {x4, y4} = point(cx, cy, r_inner, end_angle)

      Enum.join(
        [
          "M #{fmt(x1)} #{fmt(y1)}",
          "L #{fmt(x2)} #{fmt(y2)}",
          "A #{fmt(r_outer)} #{fmt(r_outer)} 0 #{large} 1 #{fmt(x3)} #{fmt(y3)}",
          "L #{fmt(x4)} #{fmt(y4)}",
          "A #{fmt(r_inner)} #{fmt(r_inner)} 0 #{large} 0 #{fmt(x1)} #{fmt(y1)}",
          "Z"
        ],
        " "
      )
    end
  end

  defp donut_path(cx, cy, r_inner, r_outer) do
    {ox1, oy1} = point(cx, cy, r_outer, 0)
    {ox2, oy2} = point(cx, cy, r_outer, :math.pi())
    {ix1, iy1} = point(cx, cy, r_inner, 0)
    {ix2, iy2} = point(cx, cy, r_inner, :math.pi())

    Enum.join(
      [
        "M #{fmt(ox1)} #{fmt(oy1)}",
        "A #{fmt(r_outer)} #{fmt(r_outer)} 0 1 1 #{fmt(ox2)} #{fmt(oy2)}",
        "A #{fmt(r_outer)} #{fmt(r_outer)} 0 1 1 #{fmt(ox1)} #{fmt(oy1)}",
        "Z",
        "M #{fmt(ix1)} #{fmt(iy1)}",
        "A #{fmt(r_inner)} #{fmt(r_inner)} 0 1 0 #{fmt(ix2)} #{fmt(iy2)}",
        "A #{fmt(r_inner)} #{fmt(r_inner)} 0 1 0 #{fmt(ix1)} #{fmt(iy1)}",
        "Z"
      ],
      " "
    )
  end

  @doc """
  Maps an angle (radians, 0 at 12 o'clock, clockwise) and radius to SVG
  coordinates: `{cx + r * sin(angle), cy - r * cos(angle)}`.
  """
  @spec point(number(), number(), number(), number()) :: {float(), float()}
  def point(cx, cy, r, angle) do
    {cx + r * :math.sin(angle), cy - r * :math.cos(angle)}
  end

  @doc """
  Deterministic color for a node key: the key hashes to a hue (0..359),
  saturation is 62%, lightness 52% for depth 1 and 64% for depth 2. The
  same key always yields the same color.
  """
  @spec color(term(), 1 | 2) :: String.t()
  def color(key, depth) do
    hue = :erlang.phash2(key, 360)
    lightness = if depth == 1, do: 52, else: 64
    "hsl(#{hue}, 62%, #{lightness}%)"
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
end
