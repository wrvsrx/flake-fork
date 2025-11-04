def isGitClean (dir : String) : IO Bool := do
  let stdout ← IO.Process.run {
    cmd := "git"
    args := #["status", "--porcelain", dir]
  }
  pure stdout.trim.isEmpty

def isOnBranch (dir : String) (branch : String) : IO Bool := do
  let stdout ← IO.Process.run {
    cmd := "git"
    args := #["branch", "--show-current"]
    cwd := some dir
  }
  pure $ stdout.trim == branch

-- -- Check externals folder status
-- def checkExternalsStatus : IO Unit := do
--   IO.println "Checking externals folder status..."
--
--   -- Check if externals folder is git clean
--   let externalsClean ← isGitClean "externals"
--   if externalsClean then
--     IO.println "✓ externals folder is git clean"
--   else
--     IO.println "✗ externals folder has uncommitted changes"
--
--   -- Check if externals/nixpkgs is on patched-nixos-unstable branch
--   let nixpkgsOnCorrectBranch ← isOnBranch "externals/nixpkgs" "patched-nixos-unstable"
--   if nixpkgsOnCorrectBranch then
--     IO.println "✓ externals/nixpkgs is on patched-nixos-unstable branch"
--   else
--     IO.println "✗ externals/nixpkgs is not on patched-nixos-unstable branch"
--
--   -- Summary
--   if externalsClean && nixpkgsOnCorrectBranch then
--     IO.println "\n✓ All checks passed!"
--   else
--     IO.println "\n✗ Some checks failed!"

def main : IO Unit := do
  if !(← isGitClean "externals")
  then throw (IO.Error.userError "externals/ is not clean")

  IO.println (← isOnBranch "externals/nixpkgs" "patched-nixos-unstable")
