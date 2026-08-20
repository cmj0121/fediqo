# Artwork

[English](README.md) | [繁體中文](README.zh-TW.md)

An octopus silhouette floating in front of a machined chassis. The creature is the only
subject; the metal behind it — silver panel, dark cut, lit chamfer, gun-metal plate, and a
slot cut through the top and bottom edges — is what the mark was before the creature arrived,
kept because the slots are where the timeline it came from is still legible.

| File              | Drawn for         | What differs                                                          |
| ----------------- | ----------------- | --------------------------------------------------------------------- |
| `logo.svg`        | 64 px and up      | Creature at 1.48×, arms drawn thin enough to curl                     |
| `logo-small.svg`  | 32 px and below   | Every metal edge on the 64-unit grid; creature at 1.30× with fat arms |
| `mascot.svg`      | Anywhere it is the subject | The same creature at 0.88 on a rounded plate, arms kept inside |

A 1024-unit canvas drawn at 16 px means **64 units to the pixel**. Anything narrower than
64 units lands mid-pixel and anti-aliasing turns it into grey, which is why `logo-small.svg`
snaps the metal to `4 px panel | 1 px cut | 1 px chamfer | 10 px plate` and thickens every
arm. The creature is drawn _smaller_ there than in `logo.svg`, not larger: fat arms need
room, and at 16 px a slightly smaller silhouette with arms that survive beats a larger one
whose arms dissolve.

Two decisions are worth keeping written down, because both were arrived at by rendering
rather than by reasoning:

- **The rim is not decoration.** A dark silhouette on mid-grey metal has no edge of its
  own; without the light rim the creature merges into the plate, and at 16 px it merges
  into the slots as well. The rim is also what let the drop shadow go — it was doing the
  same job twice, and the shadow lost.
- **Both drawings use the same metal.** An earlier small drawing brightened it to help the
  dark silhouette stand out. That produced a visible step between 32 px and 64 px, and it
  was unnecessary: the rim already carries the contrast, and the darker metal reads better
  behind it.

`mascot.svg` is the creature without the icon's job: an icon's arms are meant to bleed off
the edge, and a mascot's are meant to be seen. It is artwork in its own right and is edited
here rather than derived from `logo.svg`.

These three files are the artwork itself. Nothing here is generated, and nothing here needs
a tool to build — a raster app icon is rendered from `logo.svg` and `logo-small.svg` when
there is an app to put one in.
