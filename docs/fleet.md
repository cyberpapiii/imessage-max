# Deploying iMessage Max with MDM

This guide is for admins who install iMessage Max on many Macs through a device management (MDM) service. A configuration profile can grant the app's privacy permissions and allow its background helper, so nobody has to click through the Permissions page on each Mac.

**Untested.** Nobody has yet run this profile end to end on an MDM-enrolled Mac, from install to a first send with zero clicks. The keys and values below come from Apple's documentation and from the signed app, and each is cited. Test on one Mac before you roll it out.

Each Mac still needs what [headless.md](headless.md) describes and no profile can do: a desktop login that stays logged in, system sleep off, and a one-time iMessage sign-in in Messages.

## What the profile must grant

macOS charges the helper's privacy access to the app that contains it. The helper (`Contents/MacOS/imessage-max`, signing identifier `com.cyberpapiii.imessage-max`) runs inside `iMessage Max.app`, and each Privacy list in System Settings shows one "iMessage Max". So every rule names the app's bundle id, **`com.cyberpapiii.imessage-max.menubar`**, not the helper's identifier. A profile keyed to the helper's identifier is expected not to work. That negative case is also untested.

| What | Profile service | Why iMessage Max needs it |
| --- | --- | --- |
| Full Disk Access | `SystemPolicyAllFiles` | Read `~/Library/Messages/chat.db` |
| Contacts | `AddressBook` | Show names in place of numbers |
| Automation for Messages | `AppleEvents`, receiver `com.apple.MobileSMS` | Send through Messages |
| Background activity | Managed Login Items (`com.apple.servicemanagement`) | Let launchd run the helper and keep the user from turning it off |

Reading attachments needs nothing more. `get_attachment` transcribes audio on the Mac with `SpeechTranscriber`, which does not use the Speech Recognition service, so the profile has no `SpeechRecognition` rule.

## The app's designated requirement

Each privacy rule pins the app by its code requirement. Get it from the installed app:

```sh
codesign -dr - "/Applications/iMessage Max.app"
```

For released apps (2.0.0 and later) and for local Developer ID builds, it prints:

```text
designated => identifier "com.cyberpapiii.imessage-max.menubar" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = HJF7LN64XX
```

Use the text after `designated => ` as the `CodeRequirement`. It names the bundle id and the Developer ID team `HJF7LN64XX`, not a version or a hash, so it stays the same across updates. Check that an app on disk meets it:

```sh
codesign -v -R='identifier "com.cyberpapiii.imessage-max.menubar" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = HJF7LN64XX' "/Applications/iMessage Max.app"
```

No output and exit status 0 mean it matches. Check the team with `codesign -dvv "/Applications/iMessage Max.app" 2>&1 | grep TeamIdentifier`.

The Automation rule also pins the receiver, Messages. `codesign -dr - /System/Applications/Messages.app` prints:

```text
designated => identifier "com.apple.MobileSMS" and anchor apple
```

## Privacy Preferences Policy Control payload

The payload type is `com.apple.TCC.configuration-profile-policy`. Its `Services` dictionary holds one array per service, and each array entry is one app rule ([Apple device-management schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.TCC.configuration-profile-policy.yaml), [Apple Platform Deployment: Privacy Preferences Policy Control](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web)).

Each rule for iMessage Max uses:

- `Identifier`: `com.cyberpapiii.imessage-max.menubar`. The schema says this is case-sensitive.
- `IdentifierType`: `bundleID`. The schema says "Application bundles must be identified by bundle ID."
- `CodeRequirement`: the designated requirement above.
- `Authorization`: `Allow`. A rule has `Authorization` or the older `Allowed`, never both.
- `StaticCode`: `false`. The schema uses it "only if the process invalidates its dynamic code signature", which the app does not.

The `AppleEvents` rule adds the receiver: `AEReceiverIdentifier` `com.apple.MobileSMS`, `AEReceiverIdentifierType` `bundleID`, and `AEReceiverCodeRequirement` `identifier "com.apple.MobileSMS" and anchor apple`. The schema says these three keys are required for `AppleEvents` and not valid for any other service.

### What a profile can and cannot allow

Apple's schema documents four services that a profile can only deny: `Camera`, `Microphone`, `ListenEvent` and `ScreenCapture`. `AllowStandardUserToSetSystemService` is valid only for `ListenEvent` and `ScreenCapture`. The three services iMessage Max needs, `SystemPolicyAllFiles`, `AddressBook` and `AppleEvents`, carry no such note, so `Allow` is a documented value for each.

**Not verified for Contacts:** whether a profile's `AddressBook` Allow reads as authorized through `CNContactStore` in the helper, which is how iMessage Max checks Contacts. The companion asks for Contacts in its own process and then restarts the helper, because the helper reads Contacts access only at launch. If `diagnose` still shows `contacts.status` other than `authorized` after the profile lands, restart the helper (open the app, or run the `--register-helper` command in [headless.md](headless.md#update)).

When several profiles name the same app, "the most restrictive setting (deny) is used" (schema).

### Delivery requirements

Apple's deployment guide says this payload "Requires a device management service to install", "Requires user approval", and "Supervision is required if you apply this payload using a device management service." The schema marks it device channel only, user-approved MDM, and not manually installable. So double-clicking the `.mobileconfig` on a Mac does not grant anything. Send it from your MDM.

## Managed Login Items payload

The payload type is `com.apple.servicemanagement`, available on macOS 13 and later. It "auto-enables and auto-allows matched items", so the helper's background item is on and the user cannot turn it off in Login Items ([Apple device-management schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.servicemanagement.yaml), [Apple Platform Deployment: Managed Login Items](https://support.apple.com/guide/deployment/dep07b92494/web), [Apple Platform Deployment: login and background items](https://support.apple.com/guide/deployment/depdca572563/web)).

Each rule has a `RuleType` (`BundleIdentifier`, `BundleIdentifierPrefix`, `Label`, `LabelPrefix` or `TeamIdentifier`), a `RuleValue`, and optional `TeamIdentifier` and `Comment` keys. Two rules fit iMessage Max:

- **Team rule:** `RuleType` `TeamIdentifier`, `RuleValue` `HJF7LN64XX`. It covers every login item from this developer: the helper, and the app itself when Open at login is on.
- **Narrower rule:** `RuleType` `Label`, `RuleValue` `com.cyberpapiii.imessage-max.helper`, with `TeamIdentifier` `HJF7LN64XX`. It covers only the helper's launchd job.

The sample below uses the team rule.

## Sample profile

Replace each `REPLACE-…` value. Generate the three UUIDs with `uuidgen`. Change `com.example` to your organization's reverse-DNS prefix. Everything else is specific to iMessage Max and should stay as it is.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadDisplayName</key>
	<string>iMessage Max</string>
	<key>PayloadDescription</key>
	<string>Grants iMessage Max Full Disk Access, Contacts and Automation for Messages, and allows its background helper.</string>
	<key>PayloadIdentifier</key>
	<string>com.example.imessage-max</string>
	<key>PayloadOrganization</key>
	<string>REPLACE-ORGANIZATION-NAME</string>
	<key>PayloadScope</key>
	<string>System</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>REPLACE-UUID-PROFILE</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDisplayName</key>
			<string>iMessage Max privacy access</string>
			<key>PayloadIdentifier</key>
			<string>com.example.imessage-max.pppc</string>
			<key>PayloadType</key>
			<string>com.apple.TCC.configuration-profile-policy</string>
			<key>PayloadUUID</key>
			<string>REPLACE-UUID-PPPC</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>Services</key>
			<dict>
				<key>SystemPolicyAllFiles</key>
				<array>
					<dict>
						<key>Identifier</key>
						<string>com.cyberpapiii.imessage-max.menubar</string>
						<key>IdentifierType</key>
						<string>bundleID</string>
						<key>CodeRequirement</key>
						<string>identifier "com.cyberpapiii.imessage-max.menubar" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = HJF7LN64XX</string>
						<key>StaticCode</key>
						<false/>
						<key>Authorization</key>
						<string>Allow</string>
						<key>Comment</key>
						<string>Read ~/Library/Messages/chat.db</string>
					</dict>
				</array>
				<key>AddressBook</key>
				<array>
					<dict>
						<key>Identifier</key>
						<string>com.cyberpapiii.imessage-max.menubar</string>
						<key>IdentifierType</key>
						<string>bundleID</string>
						<key>CodeRequirement</key>
						<string>identifier "com.cyberpapiii.imessage-max.menubar" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = HJF7LN64XX</string>
						<key>StaticCode</key>
						<false/>
						<key>Authorization</key>
						<string>Allow</string>
						<key>Comment</key>
						<string>Show contact names in place of numbers</string>
					</dict>
				</array>
				<key>AppleEvents</key>
				<array>
					<dict>
						<key>Identifier</key>
						<string>com.cyberpapiii.imessage-max.menubar</string>
						<key>IdentifierType</key>
						<string>bundleID</string>
						<key>CodeRequirement</key>
						<string>identifier "com.cyberpapiii.imessage-max.menubar" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = HJF7LN64XX</string>
						<key>StaticCode</key>
						<false/>
						<key>AEReceiverIdentifier</key>
						<string>com.apple.MobileSMS</string>
						<key>AEReceiverIdentifierType</key>
						<string>bundleID</string>
						<key>AEReceiverCodeRequirement</key>
						<string>identifier "com.apple.MobileSMS" and anchor apple</string>
						<key>Authorization</key>
						<string>Allow</string>
						<key>Comment</key>
						<string>Send through Messages</string>
					</dict>
				</array>
			</dict>
		</dict>
		<dict>
			<key>PayloadDisplayName</key>
			<string>iMessage Max background helper</string>
			<key>PayloadIdentifier</key>
			<string>com.example.imessage-max.login-items</string>
			<key>PayloadType</key>
			<string>com.apple.servicemanagement</string>
			<key>PayloadUUID</key>
			<string>REPLACE-UUID-LOGIN-ITEMS</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>Rules</key>
			<array>
				<dict>
					<key>RuleType</key>
					<string>TeamIdentifier</string>
					<key>RuleValue</key>
					<string>HJF7LN64XX</string>
					<key>Comment</key>
					<string>iMessage Max app and helper (Developer ID team HJF7LN64XX)</string>
				</dict>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

`plutil -lint` passes on this file once saved. That checks only the property list syntax. Your MDM validates the payloads.

## Rollout steps

1. Send the profile from your MDM to a test Mac.
2. Install the app from the DMG or the cask (see [headless.md](headless.md#install)).
3. Log in the iMessage Max user to the desktop, open the app once, and sign in to iMessage in Messages.
4. Over SSH, as that user, run the `diagnose` check in [headless.md](headless.md#check-health-over-ssh). Expect `status` `ready`, `database` `accessible`, `contacts` `authorized`, and `perm_automation` `supported`.
5. Check that the profile shows in System Settings → General → Device Management on the Mac.
6. Roll out to the rest of the fleet only after the test Mac passes.

## Not verified yet

- The whole flow, zero clicks from install to a first send, on an MDM-enrolled Mac.
- That `AddressBook` Allow reads as authorized through `CNContactStore` in the helper.
- That the `AppleEvents` rule covers the `osascript` runs the helper starts. macOS shows the helper's own Automation prompt under the app's name, so the rule names the app.
- That a profile keyed to the helper's identifier, `com.cyberpapiii.imessage-max`, does not work.
- That on-device audio transcription runs in the launchd helper without a Speech Recognition grant. It works on macOS 27.2 in a binary started from a terminal and signed with hardened runtime and the app's entitlements.
