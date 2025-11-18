namespace Git
def getOutput
  (args: Array String)
  (cwd : Option System.FilePath := none)
  : IO String
:= do
  IO.Process.run { cmd := "git", args := args, cwd := cwd }

def runProcess
  (args: Array String)
  (cwd : Option System.FilePath := none)
  : IO Unit
:= do
  let code ← (← IO.Process.spawn { cmd := "git", args := args, cwd := cwd }).wait
  if code != 0
  then throw <| IO.userError s!"git exited with code {code}"

def isClean (dir : System.FilePath) : IO Bool := do
  pure (← getOutput #["status", "--porcelain", dir.toString]).trim.isEmpty

def isOnBranch (dir : System.FilePath) (branch : String) : IO Bool := do
  pure $ (← getOutput #["branch", "--show-current"] dir).trim == branch

def getRemotes (dir : System.FilePath) : IO (Array (String × String)) := do
  let output ← getOutput #["remote"] dir
  let remotes := String.splitOn (output.take (output.length - 1)) "\n"
  let remotesWithUrl ← remotes.mapM (
    fun remote => do
      pure (remote, ← getOutput #["remote", "get-url", remote] dir)
  )
  pure (Array.mk remotesWithUrl)
end Git


structure FlakeRepo : Type where
  name: String
  upstreamURL: String
  upstreamBranch: String

def ensureRepoUpToDate (repo: FlakeRepo) : IO Unit := do
  let dir := System.FilePath.mk "externals" / repo.name
  let patchedBranchName := "patched-" ++ repo.upstreamBranch

  if not (← Git.isOnBranch dir patchedBranchName)
  then Git.runProcess #["checkout", patchedBranchName] dir

  let remotes ← Git.getRemotes dir

  if (remotes.find? (fun (name, _) => name == "upstream")).isNone
  then Git.runProcess #["remote", "add", "upstream", repo.upstreamURL] dir

  Git.runProcess #["pull"] dir

def ensureUpToDate (repos : Array FlakeRepo) : IO Bool := do
  repos.forM ensureRepoUpToDate 
  Git.runProcess #["pull"]
  pure (← Git.isClean "externals") 

def updatePatchedBranch (repo: FlakeRepo) : IO Unit := do
  let dir := System.FilePath.mk "externals" / repo.name
  Git.runProcess #["fetch", "upstream", "--prune", "--tags"] dir
  Git.runProcess #["rebase", s!"upstream/{repo.upstreamBranch}"] dir
  Git.runProcess #["push"] dir
  if not (← Git.isClean dir.toString)
  then do
    Git.runProcess #["add", dir.toString]
    Git.runProcess #["commit", "-m", s!"chore({dir.toString}): update it"]

def repos : Array FlakeRepo := #[
  {
    name := "nixpkgs",
    upstreamURL := "https://github.com/NixOS/nixpkgs",
    upstreamBranch := "nixos-unstable"
  },
  {
    name := "home-manager",
    upstreamURL := "https://github.com/nix-community/home-manager",
    upstreamBranch := "master"
  },
  {
    name := "nixvim",
    upstreamURL := "https://github.com/nix-community/nixvim",
    upstreamBranch := "main"
  },
  {
    name := "stylix",
    upstreamURL := "https://github.com/nix-community/stylix",
    upstreamBranch := "master"
  },
]

def main : IO Unit := do
  if ← ensureUpToDate repos
  then repos.forM updatePatchedBranch
  else throw (IO.Error.userError "")
