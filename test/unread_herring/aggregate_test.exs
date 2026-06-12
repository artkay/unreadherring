defmodule UnreadHerring.AggregateTest do
  use ExUnit.Case, async: true

  alias UnreadHerring.Aggregate

  describe "parse_from/1" do
    test "quoted display name with angle-bracket address" do
      assert Aggregate.parse_from(~s("Display Name" <A@B.com>)) ==
               %{name: "Display Name", address: "a@b.com", domain: "b.com"}
    end

    test "unquoted display name with angle-bracket address" do
      assert Aggregate.parse_from("Display Name <a@b.com>") ==
               %{name: "Display Name", address: "a@b.com", domain: "b.com"}
    end

    test "bare address" do
      assert Aggregate.parse_from("a@b.com") ==
               %{name: nil, address: "a@b.com", domain: "b.com"}
    end

    test "bare address is lowercased and trimmed" do
      assert Aggregate.parse_from("  News@Example.COM  ") ==
               %{name: nil, address: "news@example.com", domain: "example.com"}
    end

    test "angle-bracket address without a name" do
      assert Aggregate.parse_from("<a@b.com>") ==
               %{name: nil, address: "a@b.com", domain: "b.com"}
    end

    test "nil input" do
      assert Aggregate.parse_from(nil) ==
               %{name: nil, address: "unknown", domain: "unknown"}
    end

    test "empty input" do
      assert Aggregate.parse_from("") ==
               %{name: nil, address: "unknown", domain: "unknown"}

      assert Aggregate.parse_from("   ") ==
               %{name: nil, address: "unknown", domain: "unknown"}
    end

    test "weird input without an address" do
      assert Aggregate.parse_from("what even is this") ==
               %{name: nil, address: "unknown", domain: "unknown"}
    end

    test "angle brackets with no usable address" do
      assert %{address: "unknown", domain: "unknown"} = Aggregate.parse_from("Someone <>")

      assert %{address: "unknown", domain: "unknown"} =
               Aggregate.parse_from("Someone <not-an-email>")
    end
  end

  describe "base_query/1" do
    test "scope and window combinations" do
      assert Aggregate.base_query(%{scope: :unread, window: :d30}) == "is:unread newer_than:30d"
      assert Aggregate.base_query(%{scope: :unread, window: :d90}) == "is:unread newer_than:90d"
      assert Aggregate.base_query(%{scope: :unread, window: :y1}) == "is:unread newer_than:1y"
      assert Aggregate.base_query(%{scope: :unread, window: :all}) == "is:unread"
      assert Aggregate.base_query(%{scope: :all, window: :d30}) == "newer_than:30d"
      assert Aggregate.base_query(%{scope: :all, window: :all}) == ""
      assert Aggregate.base_query(%{}) == ""
    end

    test "inbox: true adds in:inbox between scope and window" do
      assert Aggregate.base_query(%{scope: :unread, inbox: true, window: :d30}) ==
               "is:unread in:inbox newer_than:30d"

      assert Aggregate.base_query(%{scope: :all, inbox: true, window: :all}) == "in:inbox"
      assert Aggregate.base_query(%{scope: :unread, inbox: false, window: :all}) == "is:unread"
    end
  end

  defp msg(id, from, label_ids \\ []), do: %{id: id, from: from, label_ids: label_ids}

  defp domain_messages do
    [
      msg("1", "Alice <alice@a.com>"),
      msg("2", "alice@a.com"),
      msg("3", "Bob <bob@a.com>"),
      msg("4", "Carol <carol@b.org>")
    ]
  end

  describe "build_tree/2 with :domain grouping" do
    setup do
      {:ok, tree: Aggregate.build_tree(domain_messages(), %{group_by: :domain})}
    end

    test "root node", %{tree: tree} do
      assert tree.id == "root"
      assert tree.label == "All mail"
      assert tree.count == 4
      assert tree.query == ""
    end

    test "ring 1 counts fold by domain and sort descending", %{tree: tree} do
      assert Enum.map(tree.children, &{&1.label, &1.count}) == [{"a.com", 3}, {"b.org", 1}]
    end

    test "ring 2 counts fold by address within domain", %{tree: tree} do
      [a_com, _] = tree.children

      assert Enum.map(a_com.children, &{&1.label, &1.count}) == [
               {"alice@a.com", 2},
               {"bob@a.com", 1}
             ]
    end

    test "ids are stable paths", %{tree: tree} do
      [a_com, b_org] = tree.children
      assert a_com.id == "root/a.com"
      assert b_org.id == "root/b.org"

      assert Enum.map(a_com.children, & &1.id) == [
               "root/a.com/alice@a.com",
               "root/a.com/bob@a.com"
             ]
    end

    test "queries carry the domain/sender filters", %{tree: tree} do
      [a_com, _] = tree.children
      assert a_com.query == "from:@a.com"
      assert Enum.map(a_com.children, & &1.query) == ["from:alice@a.com", "from:bob@a.com"]
    end

    test "scope and window prefix node queries" do
      tree =
        Aggregate.build_tree(domain_messages(), %{group_by: :domain, scope: :unread, window: :d30})

      assert tree.label == "Unread everywhere"
      assert tree.query == "is:unread newer_than:30d"
      [a_com | _] = tree.children
      assert a_com.query == "is:unread newer_than:30d from:@a.com"
      [alice | _] = a_com.children
      assert alice.query == "is:unread newer_than:30d from:alice@a.com"
    end

    test "inbox scope prefixes node queries and renames the root" do
      tree =
        Aggregate.build_tree(domain_messages(), %{group_by: :domain, scope: :unread, inbox: true})

      assert tree.label == "Unread in Inbox"
      assert tree.query == "is:unread in:inbox"
      [a_com | _] = tree.children
      assert a_com.query == "is:unread in:inbox from:@a.com"
    end

    test "unparseable senders fold under unknown" do
      tree = Aggregate.build_tree([msg("1", nil), msg("2", "garbage")], %{group_by: :domain})

      assert [%{label: "unknown", count: 2, children: [%{label: "unknown", count: 2}]}] =
               tree.children
    end
  end

  describe "build_tree/2 with :sender grouping" do
    test "ring 1 is flat senders with no ring 2" do
      tree = Aggregate.build_tree(domain_messages(), %{group_by: :sender, scope: :unread})

      assert Enum.map(tree.children, &{&1.id, &1.label, &1.count}) == [
               {"root/alice@a.com", "alice@a.com", 2},
               {"root/bob@a.com", "bob@a.com", 1},
               {"root/carol@b.org", "carol@b.org", 1}
             ]

      assert Enum.all?(tree.children, &(&1.children == []))
      [alice | _] = tree.children
      assert alice.query == "is:unread from:alice@a.com"
    end
  end

  describe "build_tree/2 with :label grouping" do
    setup do
      labels = %{"Label_1" => "Newsletters", "Label_2" => "Receipts and Bills"}

      messages = [
        msg("1", "a@news.com", ["Label_1", "INBOX"]),
        msg("2", "b@news.com", ["Label_1", "Label_2"]),
        msg("3", "c@shop.com", ["Label_2"]),
        msg("4", "d@misc.com", ["INBOX", "UNREAD"])
      ]

      {:ok, tree: Aggregate.build_tree(messages, %{group_by: :label, labels: labels})}
    end

    test "multi-label message counts under both labels", %{tree: tree} do
      assert Enum.map(tree.children, &{&1.label, &1.count}) == [
               {"Newsletters", 2},
               {"Receipts and Bills", 2},
               {"(no label)", 1}
             ]
    end

    test "root count stays the message count even with multi-label", %{tree: tree} do
      assert tree.count == 4
    end

    test "label with whitespace gets a quoted query", %{tree: tree} do
      receipts = Enum.find(tree.children, &(&1.label == "Receipts and Bills"))
      assert receipts.query == ~s(label:"Receipts and Bills")
    end

    test "label without whitespace gets an unquoted query", %{tree: tree} do
      newsletters = Enum.find(tree.children, &(&1.label == "Newsletters"))
      assert newsletters.query == "label:Newsletters"
    end

    test "a label name containing a double quote gets no query at all" do
      # Gmail cannot escape a quote inside a quoted phrase; any rewrite
      # would target a DIFFERENT label, so the bucket must be unsearchable.
      labels = %{"Label_9" => ~s(My "fancy" label)}
      messages = [msg("1", "a@news.com", ["Label_9"])]

      tree = Aggregate.build_tree(messages, %{group_by: :label, labels: labels})
      [label_node] = tree.children

      assert label_node.label == ~s(My "fancy" label)
      assert label_node.query == nil
      assert Enum.all?(label_node.children, &is_nil(&1.query))
    end

    test "no user label goes under (no label) with has:nouserlabels", %{tree: tree} do
      no_label = Enum.find(tree.children, &(&1.label == "(no label)"))
      assert no_label.id == "root/(no label)"
      assert no_label.count == 1
      assert no_label.query == "has:nouserlabels"
      assert [%{label: "misc.com", query: "has:nouserlabels from:@misc.com"}] = no_label.children
    end

    test "ring 2 is domains within the label", %{tree: tree} do
      newsletters = Enum.find(tree.children, &(&1.label == "Newsletters"))

      assert [%{id: "root/Newsletters/news.com", label: "news.com", count: 2, query: query}] =
               newsletters.children

      assert query == "label:Newsletters from:@news.com"
    end

    test "nested query combines scope, label and domain filters" do
      labels = %{"L" => "Big News"}
      messages = [msg("1", "a@news.com", ["L"])]
      tree = Aggregate.build_tree(messages, %{group_by: :label, labels: labels, scope: :unread})

      [label_node] = tree.children
      [domain_node] = label_node.children
      assert domain_node.query == ~s(is:unread label:"Big News" from:@news.com)
    end
  end

  describe "find_node/2 and path_to/2" do
    setup do
      {:ok, tree: Aggregate.build_tree(domain_messages(), %{group_by: :domain})}
    end

    test "find_node returns the root", %{tree: tree} do
      assert Aggregate.find_node(tree, "root") == tree
    end

    test "find_node returns nested nodes", %{tree: tree} do
      assert %{label: "a.com"} = Aggregate.find_node(tree, "root/a.com")
      assert %{label: "bob@a.com", count: 1} = Aggregate.find_node(tree, "root/a.com/bob@a.com")
    end

    test "find_node returns nil for unknown ids", %{tree: tree} do
      assert Aggregate.find_node(tree, "root/nope") == nil
      assert Aggregate.find_node(tree, "root/a.com/nope@a.com") == nil
    end

    test "path_to walks root to node inclusive", %{tree: tree} do
      assert [%{id: "root"}, %{id: "root/a.com"}, %{id: "root/a.com/alice@a.com"}] =
               Aggregate.path_to(tree, "root/a.com/alice@a.com")

      assert [%{id: "root"}] = Aggregate.path_to(tree, "root")
    end

    test "path_to returns nil for unknown ids", %{tree: tree} do
      assert Aggregate.path_to(tree, "root/missing") == nil
    end
  end
end
