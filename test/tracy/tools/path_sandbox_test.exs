defmodule Tracy.Tools.PathSandboxTest do
  use ExUnit.Case, async: true

  alias Tracy.Tools.PathSandbox

  describe "resolve_path/2" do
    test "allows paths under an allowed base" do
      base = "/tmp/tracy-sandbox-test"
      File.mkdir_p!(base)
      assert {:ok, resolved} = PathSandbox.resolve_path("file.txt", [base])
      assert String.starts_with?(resolved, base)
    end

    test "rejects paths that traverse outside" do
      assert {:error, msg} = PathSandbox.resolve_path("../../etc/passwd", ["/tmp/tracy-sandbox-test"])
      assert msg =~ "Access denied"
    end

    test "rejects absolute paths outside allowed bases" do
      assert {:error, _} = PathSandbox.resolve_path("/etc/passwd", ["/tmp/tracy-sandbox-test"])
    end

    test "expands ~ relative to home" do
      assert {:ok, resolved} = PathSandbox.resolve_path("~/some-file", [System.user_home!()])
      assert resolved == Path.join(System.user_home!(), "some-file")
    end
  end

  describe "allowed?/2" do
    test "true for path under base" do
      assert PathSandbox.allowed?("/tmp/tracy-sandbox-test/x", ["/tmp/tracy-sandbox-test"])
    end

    test "false for sibling directory" do
      refute PathSandbox.allowed?("/tmp/other", ["/tmp/tracy-sandbox-test"])
    end
  end
end
