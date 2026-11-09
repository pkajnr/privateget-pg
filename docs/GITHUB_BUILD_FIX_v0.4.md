# PrivateGet PG: fix repeated GitHub Actions MyApp test error

## Symptoms

`flutter analyze` fails with 17 errors in `mobile/test/widget_test.dart`, including
`package:flutter_test/flutter_test.dart` missing and `MyApp` not found.

## Resolution (one file)

1. In GitHub, open your repository `privateget-pg`.
2. Open `scripts/prepare-mobile.sh`, select **Edit**.
3. Replace its entire contents with the file from `PrivateGet_PG_One_File_Fix_v0.4.zip`.
4. Commit the change to the branch used for **Actions → Build PG Android alpha APK**.
5. Rerun the workflow (do not rerun the old failed job if it still targets an old commit).
6. Check **Create native project**. It should show **Checking PG Flutter tests...**
   and then **Checking PG Flutter analyzer...**.

If the job does not contain those new lines, the workflow is building an old commit
or the file was uploaded into the wrong directory.

### Why this works

Flutter may generate its example counter test inside `flutter create`.
PG's script now replaces that file **after** `flutter create`, ensures
`flutter_test` is present as a Flutter-SDK dev dependency, and then runs
`flutter pub get`, `flutter test`, and `flutter analyze`. It works even if the old
pubspec or test file is still present in GitHub.

The Android APK itself has **not** been compiled in this packaging environment.
New Android or Gradle errors, if any, are separate and should be resolved from
that workflow log. This is a developmental alpha, not a privacy-certified messenger.
