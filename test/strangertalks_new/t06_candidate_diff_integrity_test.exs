defmodule StrangertalksNew.T06CandidateDiffIntegrityTest do
  use ExUnit.Case, async: false

  @script Path.expand("ops/check_candidate_diff.sh")

  test "inherited ancient whitespace is ignored while candidate-introduced whitespace fails" do
    assert File.exists?(@script)

    root = Path.join(System.tmp_dir!(), "t06-diff-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init"])
    git!(root, ["config", "user.email", "t06@example.invalid"])
    git!(root, ["config", "user.name", "T06 Test"])

    File.write!(Path.join(root, "legacy.txt"), "inherited trailing whitespace   \n")
    git!(root, ["add", "legacy.txt"])
    git!(root, ["commit", "-m", "ancient whitespace"])

    File.write!(Path.join(root, "base.txt"), "canonical base\n")
    git!(root, ["add", "base.txt"])
    git!(root, ["commit", "-m", "canonical base"])
    base_sha = git_output!(root, ["rev-parse", "HEAD"])

    File.write!(Path.join(root, "candidate.txt"), "clean candidate\n")
    git!(root, ["add", "candidate.txt"])
    git!(root, ["commit", "-m", "clean candidate"])
    clean_candidate_sha = git_output!(root, ["rev-parse", "HEAD"])

    assert {_output, 0} =
             System.cmd("bash", [@script, base_sha, clean_candidate_sha], cd: root, stderr_to_stdout: true)

    File.write!(Path.join(root, "candidate_bad.txt"), "candidate trailing whitespace   \n")
    git!(root, ["add", "candidate_bad.txt"])
    git!(root, ["commit", "-m", "bad candidate whitespace"])
    bad_candidate_sha = git_output!(root, ["rev-parse", "HEAD"])

    assert {output, exit_code} =
             System.cmd("bash", [@script, base_sha, bad_candidate_sha], cd: root, stderr_to_stdout: true)

    assert exit_code != 0
    assert output =~ "candidate_bad.txt"
  end

  defp git!(root, args) do
    {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end

  defp git_output!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end
end
