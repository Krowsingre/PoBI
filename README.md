# Plate or Break It

A GPS game for iPhone about eating your way across New Jersey. Players rate real restaurants, cafés and bars (Plate It or Break It, one to three stars), check in, and fight for ownership of establishments and areas on one of three teams.

The game rules are recorded in the [decisions doc](https://claude.ai/artifact/YS91THrAyzvEsFYKt8GgW1).

## Repository layout

| Folder | What it is |
| --- | --- |
| `engine/` | The game rules engine, its tests and a simulator. Plain TypeScript with no dependencies, so the same code can run on the server. |
| `ios/` | The iPhone app (SwiftUI, iOS 17+, bundle ID `com.krowsingre.pobi`). The Xcode project is generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). |

## iPhone builds

Every pull request that touches `ios/` is built on a GitHub Mac runner. Every merge to `main` that touches `ios/` is archived and uploaded to TestFlight, using these repository secrets: `APPLE_TEAM_ID`, `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_PRIVATE_KEY`.

To build on a Mac: `brew install xcodegen`, then `cd ios && xcodegen generate && open PoBI.xcodeproj`.

The backend comes next.
