# Plate or Break It

A GPS game for iPhone about eating your way across New Jersey. Players rate real restaurants, cafés and bars (Plate It or Break It, one to three stars), check in, and fight for ownership of establishments and areas on one of three teams.

The game rules are recorded in the [decisions doc](https://claude.ai/artifact/YS91THrAyzvEsFYKt8GgW1).

## Repository layout

| Folder | What it is |
| --- | --- |
| `engine/` | The game rules engine, its tests and a simulator. Plain TypeScript with no dependencies, so the same code can run on the server. |

The iPhone app (SwiftUI, bundle ID `com.krowsingre.pobi`) and the backend come next.
