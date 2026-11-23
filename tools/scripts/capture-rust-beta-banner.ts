import { copyFileSync, mkdirSync } from "node:fs"
import { resolve } from "node:path"

const root = resolve(import.meta.dir, "../..")
const output = resolve(root, "build/banner-screenshots")
const log = resolve(root, "build/banner-preview.log")
const result = resolve(root, `build/banner-capture-${Date.now()}.xcresult`)
const attachments = resolve(output, `attachments-${Date.now()}`)
mkdirSync(output, { recursive: true })
await Bun.write(log, "")

const child = Bun.spawn([
  "xcodebuild", "-project", "Hex.xcodeproj", "-scheme", "Hex", "-configuration", "Debug",
  "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "build/banner-preview",
  "-resultBundlePath", result,
  "-clonedSourcePackagesDirPath", process.env.HEX_PREVIEW_PACKAGES ?? resolve(root, "build/banner-packages"),
  "-onlyUsePackageVersionsFromResolvedFile", "-skipMacroValidation", "-skipPackagePluginValidation",
  "-only-testing:HexTests/RustBetaBannerTests", "-parallel-testing-enabled", "NO",
  "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=",
  "PRODUCT_BUNDLE_IDENTIFIER=ly.anoma.Hex.LegacyBannerPreview", "SWIFT_EMIT_LOC_STRINGS=NO", "test",
], {
  cwd: root,
  env: { ...process.env, TEST_RUNNER_HEX_BANNER_SCREENSHOTS: "1" },
  stdout: Bun.file(log), stderr: "inherit",
})
const status = await child.exited
if (status !== 0) {
  console.error((await Bun.file(log).text()).split("\n").slice(-40).join("\n"))
  process.exit(status)
}

const exported = Bun.spawnSync([
  "xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", attachments,
])
if (exported.exitCode !== 0) {
  console.error(exported.stderr.toString())
  process.exit(exported.exitCode)
}
const manifest = await Bun.file(resolve(attachments, "manifest.json")).json()
const captured = new Set<string>()
for (const test of manifest) {
  for (const attachment of test.attachments) {
    const name = attachment.suggestedHumanReadableName.match(/^Rust beta Settings - (light|dark|narrow|dismissed)_/)?.[1]
    if (!name) continue
    const path = resolve(output, `rust-beta-settings-${name}.png`)
    copyFileSync(resolve(attachments, attachment.exportedFileName), path)
    captured.add(name)
    console.log(path)
  }
}
if (captured.size !== 4) throw new Error("Expected all four Settings screenshots")
