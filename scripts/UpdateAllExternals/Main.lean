namespace Git

structure Result where
  exitCode : UInt32
  stdout : String
  stderr : String

def output (cwd : Option System.FilePath) (args : Array String) : IO Result := do
  let result ← IO.Process.output { cmd := "git", args := args, cwd := cwd }
  pure { exitCode := result.exitCode, stdout := result.stdout, stderr := result.stderr }

def getOutput (cwd : Option System.FilePath) (args : Array String) : IO String := do
  let result ← output cwd args
  if result.exitCode == 0 then
    pure result.stdout
  else
    throw <| IO.userError s!"git {String.intercalate " " args.toList} failed:\n{result.stderr}"

def runProcess (cwd : Option System.FilePath) (args : Array String) : IO Unit := do
  let code ← (← IO.Process.spawn { cmd := "git", args := args, cwd := cwd }).wait
  if code != 0 then
    throw <| IO.userError s!"git exited with code {code}"

def succeeds (cwd : Option System.FilePath) (args : Array String) : IO Bool := do
  pure ((← output cwd args).exitCode == 0)

def isClean (dir : System.FilePath) : IO Bool := do
  pure (← getOutput dir #["status", "--porcelain"]).trimAscii.isEmpty

def isOnBranch (dir : System.FilePath) (branch : String) : IO Bool := do
  pure $ (← getOutput dir #["branch", "--show-current"]).trimAscii == branch

def revParse (dir : System.FilePath) (revision : String) : IO String := do
  pure (← getOutput dir #["rev-parse", "--verify", revision ++ "^{commit}"]).trimAscii.toString

def remoteTip (dir : System.FilePath) (remote : String) (branch : String) : IO String := do
  let output ← getOutput dir #["ls-remote", "--heads", remote, s!"refs/heads/{branch}"]
  let line := output.trimAscii.toString
  if line.isEmpty then
    throw <| IO.userError s!"remote branch {remote}/{branch} does not exist"
  else
    match line.splitOn "\t" with
    | oid :: _ => pure oid
    | [] => throw <| IO.userError s!"could not parse remote branch {remote}/{branch}"

def lines (value : String) : List String :=
  (value.splitOn "\n").map (fun line => line.trimAscii.toString) |>.filter (!·.isEmpty)

end Git

structure FlakeRepo : Type where
  name : String
  upstreamURL : String
  upstreamBranch : String
  originBranch : Option String := none

def patchedBranchName (repo : FlakeRepo) : String :=
  repo.originBranch.getD ("patched-" ++ repo.upstreamBranch)

def repoDir (repo : FlakeRepo) : System.FilePath :=
  System.FilePath.mk "externals" / repo.name

def ensureRemote (dir : System.FilePath) (name url : String) : IO Unit := do
  let remoteExists ← Git.succeeds dir #["remote", "get-url", name]
  if !remoteExists then
    Git.runProcess dir #["remote", "add", name, url]

def fetchOrigin (dir : System.FilePath) (branch : String) : IO Unit := do
  Git.runProcess dir #[
    "fetch", "origin", "--prune",
    s!"+refs/heads/{branch}:refs/remotes/origin/{branch}",
    "+refs/tags/tag_rebase-*:refs/tags/tag_rebase-*"
  ]

def ensureRepoReady (repo : FlakeRepo) : IO Unit := do
  let dir := repoDir repo
  let branch := patchedBranchName repo
  if !(← Git.isClean dir) then
    throw <| IO.userError s!"{dir} has uncommitted changes; refusing to update it"
  if !(← Git.isOnBranch dir branch) then
    Git.runProcess dir #["checkout", branch]
  ensureRemote dir "upstream" repo.upstreamURL
  fetchOrigin dir branch
  if ← Git.succeeds dir #["merge-base", "--is-ancestor", "HEAD", s!"origin/{branch}"] then
    Git.runProcess dir #["merge", "--ff-only", s!"origin/{branch}"]

def patchStackIsEquivalent
    (dir : System.FilePath) (oldOrigin upstreamTip newHead : String) : IO Bool := do
  let oldBase ← Git.getOutput dir #["merge-base", oldOrigin, upstreamTip]
  let oldRange := s!"{oldBase.trimAscii.toString}..{oldOrigin}"
  let newRange := s!"{upstreamTip}..{newHead}"
  let oldCount ← Git.getOutput dir #["rev-list", "--count", oldRange]
  let newCount ← Git.getOutput dir #["rev-list", "--count", newRange]
  if oldCount.trimAscii.toString != newCount.trimAscii.toString then
    pure false
  else
    let comparison ← Git.output dir #["range-diff", "--no-color", oldRange, newRange]
    if comparison.exitCode != 0 then
      pure false
    else
      let comparisonLines := Git.lines comparison.stdout
      let expectedCount := oldCount.trimAscii.toString.toNat?.getD 0
      pure <| comparisonLines.length == expectedCount &&
        comparisonLines.all (fun line => (line.splitOn " = ").length == 2)

def paddedTagNumber (number : Nat) : String :=
  let digits := toString number
  String.ofList (List.replicate (3 - min 3 digits.length) '0') ++ digits

def nextBackupTag (dir : System.FilePath) : IO String := do
  let output ← Git.getOutput dir #["tag", "--list", "tag_rebase-*", "--sort=version:refname"]
  let numbers := (Git.lines output).filterMap fun tag =>
    (tag.dropPrefix? "tag_rebase-").bind (fun suffix => suffix.toString.toNat?)
  let next := numbers.foldl max 0 + 1
  pure s!"tag_rebase-{paddedTagNumber next}"

def existingBackupTag (dir : System.FilePath) (oid : String) : IO (Option String) := do
  let output ← Git.getOutput dir #[
    "for-each-ref", "--points-at", oid, "--format=%(refname:short)", "refs/tags/tag_rebase-*"
  ]
  pure (Git.lines output).head?

def remoteTagTip (dir : System.FilePath) (tag : String) : IO (Option String) := do
  let result ← Git.output dir #["ls-remote", "--tags", "origin", s!"refs/tags/{tag}"]
  if result.exitCode != 0 then
    pure none
  else
    match Git.lines result.stdout with
    | line :: _ => pure (line.splitOn "\t").head?
    | [] => pure none

partial def pushBackupTag (dir : System.FilePath) (oldOrigin : String) (attempts : Nat := 8) : IO String := do
  if attempts == 0 then
    throw <| IO.userError "could not allocate a tag_rebase-NNN backup tag after repeated races"
  let tag ← match ← existingBackupTag dir oldOrigin with
    | some tag => pure tag
    | none =>
      let tag ← nextBackupTag dir
      Git.runProcess dir #["tag", tag, oldOrigin]
      pure tag
  let push ← Git.output dir #["push", "origin", s!"refs/tags/{tag}:refs/tags/{tag}"]
  if push.exitCode == 0 then
    pure tag
  else
    match ← remoteTagTip dir tag with
    | some oid =>
      if oid == oldOrigin then
        pure tag
      else
        if (← Git.revParse dir tag) == oldOrigin then
          Git.runProcess dir #["tag", "-d", tag]
        fetchOrigin dir ((← Git.getOutput dir #["branch", "--show-current"]).trimAscii.toString)
        pushBackupTag dir oldOrigin (attempts - 1)
    | none =>
      throw <| IO.userError s!"failed to push backup tag {tag}:\n{push.stderr}"

def pushRebasedBranch
    (dir : System.FilePath) (branch oldOrigin upstreamTip : String) : IO Unit := do
  let newHead ← Git.revParse dir "HEAD"
  let normalPush ← Git.output dir #["push", "origin", s!"HEAD:refs/heads/{branch}"]
  if normalPush.exitCode == 0 then
    return
  let currentRemote ← Git.remoteTip dir "origin" branch
  if currentRemote == newHead then
    return
  if currentRemote != oldOrigin then
    throw <| IO.userError s!"origin/{branch} changed concurrently; refusing to force-push"
  if !(← patchStackIsEquivalent dir oldOrigin upstreamTip newHead) then
    throw <| IO.userError s!"the patch stack for {branch} is not provably equivalent after rebase"
  let tag ← pushBackupTag dir oldOrigin
  let remoteAfterTag ← Git.remoteTip dir "origin" branch
  if remoteAfterTag != oldOrigin then
    throw <| IO.userError s!"origin/{branch} changed after backup tag {tag} was pushed"
  let forcePush ← Git.output dir #[
    "push", s!"--force-with-lease=refs/heads/{branch}:{oldOrigin}",
    "origin", s!"HEAD:refs/heads/{branch}"
  ]
  if forcePush.exitCode != 0 then
    let finalRemote ← Git.remoteTip dir "origin" branch
    if finalRemote != newHead then
      throw <| IO.userError s!"lease-protected push of {branch} failed:\n{forcePush.stderr}"

def commitGitlink (repo : FlakeRepo) : IO Unit := do
  let dir := repoDir repo
  if !(← Git.succeeds none #["diff", "--quiet", "HEAD", "--", dir.toString]) then
    Git.runProcess none #[
      "commit", "--only", "-m", s!"chore({dir}): update it", "--", dir.toString
    ]

def updatePatchedBranch (repo : FlakeRepo) : IO Unit := do
  let dir := repoDir repo
  let branch := patchedBranchName repo
  ensureRepoReady repo
  let oldOrigin ← Git.revParse dir s!"origin/{branch}"
  Git.runProcess dir #["fetch", "upstream", "--prune", repo.upstreamBranch]
  let upstreamTip ← Git.revParse dir "FETCH_HEAD"
  Git.runProcess dir #["rebase", upstreamTip]
  pushRebasedBranch dir branch oldOrigin upstreamTip
  commitGitlink repo

def repos : Array FlakeRepo := #[
  {
    name := "nixpkgs"
    upstreamURL := "https://github.com/NixOS/nixpkgs"
    originBranch := some "patched-nixos-unstable"
    upstreamBranch := "nixos-unstable"
  },
  {
    name := "home-manager"
    upstreamURL := "https://github.com/nix-community/home-manager"
    upstreamBranch := "master"
  },
  {
    name := "sops-nix"
    upstreamURL := "https://github.com/Mic92/sops-nix"
    upstreamBranch := "master"
  },
  {
    name := "stylix"
    upstreamURL := "https://github.com/nix-community/stylix"
    upstreamBranch := "master"
  },
]

def selectedRepos (args : List String) : IO (Array FlakeRepo) := do
  match args with
  | [] => pure repos
  | ["--repo", name, upstreamURL, upstreamBranch, originBranch] =>
    pure #[{
      name
      upstreamURL
      upstreamBranch
      originBranch := if originBranch == "-" then none else some originBranch
    }]
  | _ => throw <| IO.userError "usage: updateallexternals [--repo NAME UPSTREAM_URL UPSTREAM_BRANCH ORIGIN_BRANCH_OR_DASH]"

def main (args : List String) : IO Unit := do
  for repo in ← selectedRepos args do
    updatePatchedBranch repo
