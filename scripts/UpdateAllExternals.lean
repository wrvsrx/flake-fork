def isGitClean (dir : String) : IO Bool := do
  let stdout ← IO.Process.run {
    cmd := "git"
    args := #["status", "--porcelain", dir]
  }
  pure stdout.trim.isEmpty

def isOnBranch (dir : System.FilePath) (branch : String) : IO Bool := do
  let stdout ← IO.Process.run {
    cmd := "git"
    args := #["branch", "--show-current"]
    cwd := dir
  }
  pure $ stdout.trim == branch

def runProcess (args : IO.Process.SpawnArgs) := do
  let code ← (← IO.Process.spawn args).wait
  if code != 0
  then throw <| IO.userError s!"git exited with code {code}"

def getGitRemotes (dir : System.FilePath) : IO (Array (String × String)) := do
  let output ← IO.Process.run {
    cmd := "git"
    args := #["remote"]
    cwd := dir
  }
  let remotes := String.splitOn (output.take (output.length - 1)) "\n"
  let remotesWithUrl ← remotes.mapM (
    fun remote => do
      let output ← IO.Process.run { cmd := "git", args := #["remote", "get-url", remote], cwd := dir }
      pure (remote, output)
  )
  pure (Array.mk remotesWithUrl)

structure FlakeRepo : Type where
  name: String
  upstreamURL: String
  upstreamBranch: String

def ensureRepoUpToDate (repo: FlakeRepo) : IO Unit := do
  let dir := System.FilePath.mk "externals" / repo.name
  let patchedBranchName := "patched-" ++ repo.upstreamBranch

  if not (← isOnBranch dir patchedBranchName)
  then runProcess { cmd := "git", args := #["checkout", patchedBranchName], cwd := some dir }

  let remotes ← getGitRemotes dir

  if (remotes.find? (fun (name, _) => name == "upstream")).isNone
  then runProcess { cmd := "git", args := #["remote", "add", "upstream", repo.upstreamURL], cwd := dir }

  runProcess { cmd := "git", args := #["pull"], cwd := dir }

def ensureUpToDate (repos : Array FlakeRepo) : IO Bool := do
  repos.forM ensureRepoUpToDate 
  _ ← IO.Process.run { cmd := "git", args := #["pull"] }
  pure (← isGitClean "externals") 

def updatePatchedBranch (repo: FlakeRepo) : IO Unit := do
  let dir := System.FilePath.mk "externals" / repo.name
  runProcess { cmd := "git", args := #["fetch", "upstream", "--prune", "--tags"], cwd := dir }
  runProcess { cmd := "git", args := #["rebase", s!"upstream/{repo.upstreamBranch}"], cwd := dir }
  if not (← isGitClean dir.toString)
  then do
    runProcess { cmd := "git", args := #["add", dir.toString]}
    runProcess { cmd := "git", args := #["commit", "-m", s!"chore({dir.toString}): update it"]}

def repos : Array FlakeRepo := #[
  { name := "nixpkgs", upstreamURL := "https://github.com/NixOS/nixpkgs", upstreamBranch := "nixos-unstable" },
  { name := "home-manager", upstreamURL := "https://github.com/nix-community/home-manager", upstreamBranch := "master" },
  { name := "nixvim", upstreamURL := "https://github.com/nix-community/nixvim", upstreamBranch := "main" },
  { name := "stylix", upstreamURL := "https://github.com/nix-community/stylix", upstreamBranch := "master" },
]

def main : IO Unit := do
  if ← ensureUpToDate repos
  then repos.forM updatePatchedBranch
  else throw (IO.Error.userError "")
