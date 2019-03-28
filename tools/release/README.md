Release Engineering
===================

This repository contains hacks, scripts and tooling for building
binary releases of Futhark.

For a binary release on a POSIXy system, the directory `skeleton` is
populated with compiled binaries and manpages and turned into a
tarball.

Release Procedure
-----------------

When making a release, we not only make a binary release, we also make
a source release based on a specific Git commit.  A source release
corresponds exactly to the state of the Git repository at some point.

 * Decide on a version number X.Y.Z.  Remember that only unreleased
   versions have Z=0.

 * Find a commit that would make for a good release.  Make sure it is
   at least minimally functional.

 * Verify that `CHANGELOG.md` is updated, and that the most recent
   entries refer to the correct version number.

 * Verify the version number in `package.yaml`.

 * Make sure you've committed any changes you may have made due to the
   previous two steps.

 * Run `git tag vX.Y.Z`.

 * Push the tag: `git push --tags`.  This counts as a release on
   Github.

 * Go to `https://github.com/diku-dk/futhark/releases` and copy
   release notes from `CHANGELOG.md`.

You're done!  Congratulations!  Increment the version number in
`package.yaml` (such that Z=0) and make room for a new release in
`CHANGELOG.md` and go hack some more on the compiler.

The following steps are for making the release available elsewhere.
Some of them are supposed to be automatic.

 * **This is done automatically by a Travis job**: Run
   `tools/release/binary-tarball.sh . -X.Y.Z-linux-x86_64`.  This
   produces `futhark-X.Y.Z-linux-x86_64.xz`.  Put this tarball in some
   public location and make sure its permissions make it readable.

  * Update the Homebrew formula with `brew bump-formula-pr
    --url=https://github.com/diku-dk/futhark/archive/vX.Y.Z.tar.gz
    futhark --verbose`.  This may take significant previous setup.
