defmodule UnreadHerring.SunburstTest do
  use ExUnit.Case, async: true

  alias UnreadHerring.Aggregate
  alias UnreadHerring.Sunburst

  @two_pi 2 * :math.pi()

  defp msg(id, from, label_ids \\ []), do: %{id: id, from: from, label_ids: label_ids}

  defp sample_tree do
    Aggregate.build_tree(
      [
        msg("1", "alice@a.com"),
        msg("2", "alice@a.com"),
        msg("3", "bob@a.com"),
        msg("4", "carol@b.org")
      ],
      %{group_by: :domain}
    )
  end

  describe "segments/2" do
    test "ring 1 angles sum to 2*pi" do
      ring1 = sample_tree() |> Sunburst.segments() |> Enum.filter(&(&1.depth == 1))

      total = Enum.reduce(ring1, 0.0, fn s, acc -> acc + (s.end_angle - s.start_angle) end)
      assert_in_delta total, @two_pi, 1.0e-9
      assert_in_delta List.first(ring1).start_angle, 0.0, 1.0e-9
      assert_in_delta List.last(ring1).end_angle, @two_pi, 1.0e-9
    end

    test "shares are fractions of the current root count" do
      segments = Sunburst.segments(sample_tree())
      by_id = Map.new(segments, &{&1.node_id, &1})

      assert_in_delta by_id["root/a.com"].share, 3 / 4, 1.0e-9
      assert_in_delta by_id["root/b.org"].share, 1 / 4, 1.0e-9
      assert_in_delta by_id["root/a.com/alice@a.com"].share, 2 / 4, 1.0e-9
    end

    test "ring 2 children fill exactly the parent span" do
      segments = Sunburst.segments(sample_tree())
      parent = Enum.find(segments, &(&1.node_id == "root/a.com"))
      kids = segments |> Enum.filter(&String.starts_with?(&1.node_id, "root/a.com/"))

      assert length(kids) == 2
      assert_in_delta List.first(kids).start_angle, parent.start_angle, 1.0e-9
      assert_in_delta List.last(kids).end_angle, parent.end_angle, 1.0e-9

      span_sum = Enum.reduce(kids, 0.0, fn s, acc -> acc + (s.end_angle - s.start_angle) end)
      assert_in_delta span_sum, parent.end_angle - parent.start_angle, 1.0e-9
    end

    test "depth and radii match the rings" do
      segments = Sunburst.segments(sample_tree())
      r0 = Sunburst.hole_radius()
      rw = Sunburst.ring_width()

      for s <- segments do
        case s.depth do
          1 ->
            assert s.r_inner == r0
            assert s.r_outer == r0 + rw

          2 ->
            assert s.r_inner == r0 + rw
            assert s.r_outer == r0 + 2 * rw
        end
      end

      assert Enum.any?(segments, &(&1.depth == 1))
      assert Enum.any?(segments, &(&1.depth == 2))
    end

    test "has_children? reflects the tree" do
      segments = Sunburst.segments(sample_tree())
      by_id = Map.new(segments, &{&1.node_id, &1})

      assert by_id["root/a.com"].has_children?
      refute by_id["root/a.com/alice@a.com"].has_children?
    end

    test "colors are deterministic: same input twice gives identical output" do
      assert Sunburst.segments(sample_tree()) == Sunburst.segments(sample_tree())
      assert Sunburst.color("a.com", 1) == Sunburst.color("a.com", 1)
      assert Sunburst.color("a.com", 1) =~ ~r/^hsl\(\d+, 62%, 52%\)$/
      assert Sunburst.color("a.com", 2) =~ ~r/^hsl\(\d+, 62%, 64%\)$/
    end

    test "single child produces a valid full-circle path" do
      tree =
        Aggregate.build_tree([msg("1", "a@solo.com"), msg("2", "a@solo.com")], %{
          group_by: :domain
        })

      [seg | _] = Sunburst.segments(tree)

      assert_in_delta seg.end_angle - seg.start_angle, @two_pi, 1.0e-9
      assert seg.path_d =~ "A"
      refute seg.path_d =~ "NaN"
      refute seg.path_d =~ "Infinity"
    end

    test "empty tree yields no segments" do
      tree = Aggregate.build_tree([], %{group_by: :domain})
      assert Sunburst.segments(tree) == []
    end

    test "nil and \"root\" target the tree root" do
      tree = sample_tree()
      assert Sunburst.segments(tree, nil) == Sunburst.segments(tree)
      assert Sunburst.segments(tree, "root") == Sunburst.segments(tree)
    end

    test "unknown root id falls back to the tree root" do
      tree = sample_tree()
      assert Sunburst.segments(tree, "root/nope") == Sunburst.segments(tree)
    end

    test "re-rooting on a ring-1 node id makes its children ring 1" do
      segments = Sunburst.segments(sample_tree(), "root/a.com")
      ring1 = Enum.filter(segments, &(&1.depth == 1))

      assert Enum.map(ring1, & &1.node_id) == ["root/a.com/alice@a.com", "root/a.com/bob@a.com"]
      assert Enum.all?(segments, &(&1.depth == 1))

      total = Enum.reduce(ring1, 0.0, fn s, acc -> acc + (s.end_angle - s.start_angle) end)
      assert_in_delta total, @two_pi, 1.0e-9

      alice = Enum.find(ring1, &(&1.node_id == "root/a.com/alice@a.com"))
      assert_in_delta alice.share, 2 / 3, 1.0e-9
    end
  end

  describe "arc_path/6" do
    test "partial arc starts with M, ends with Z, has finite numbers" do
      d = Sunburst.arc_path(300, 300, 88, 180, 0.0, :math.pi() / 2)

      assert String.starts_with?(d, "M")
      assert String.ends_with?(d, "Z")
      assert d =~ "A"
      refute d =~ "NaN"
      refute d =~ "Infinity"
    end

    test "large arc sets the large-arc-flag" do
      small = Sunburst.arc_path(300, 300, 88, 180, 0.0, :math.pi() / 2)
      large = Sunburst.arc_path(300, 300, 88, 180, 0.0, 1.5 * :math.pi())

      assert small =~ " 0 0 1 "
      assert large =~ " 0 1 1 "
    end

    test "full circle emits a two-subpath donut" do
      d = Sunburst.arc_path(300, 300, 88, 180, 0.0, @two_pi)

      assert String.starts_with?(d, "M")
      assert String.ends_with?(d, "Z")
      assert length(String.split(d, "M ")) - 1 == 2
      assert length(String.split(d, "A ")) - 1 == 4
      refute d =~ "NaN"
      refute d =~ "Infinity"
    end
  end

  describe "point/4" do
    test "0 rad is 12 o'clock, clockwise" do
      {x, y} = Sunburst.point(300, 300, 100, 0)
      assert_in_delta x, 300.0, 1.0e-9
      assert_in_delta y, 200.0, 1.0e-9

      {x, y} = Sunburst.point(300, 300, 100, :math.pi() / 2)
      assert_in_delta x, 400.0, 1.0e-9
      assert_in_delta y, 300.0, 1.0e-9
    end
  end

  describe "geometry constants" do
    test "exposed for the LiveView" do
      assert Sunburst.view_box() == "0 0 600 600"
      assert Sunburst.center() == {300, 300}
      assert Sunburst.hole_radius() == 88
      assert Sunburst.ring_width() == 92
    end
  end
end
