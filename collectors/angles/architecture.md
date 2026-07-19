---
id: architecture
label: アーキテクチャ整合性
skill: architecture-review
---

PR の変更が既存アーキテクチャ(層構造・依存方向・単一責任・過剰実装の有無)と整合しているかを探す。diff で新規追加/変更された箇所に限定し、既存コードの一般論は挙げない。判定(severity 付与・採否)は行わず、候補の列挙に留める。

<!--
issue #65 の実例: skill 委譲(パターン A)を示す 9 番目の観点。
`skill: architecture-review` が指す skill は kit に同梱しない(可搬性の対象外・multi-angle モードと同じ扱い)。
finder は Skill ツールでこの skill が見つからない場合、この観点だけ候補 0 件として fail-open してよい
(collectors/strategy.md の「未応答/角度が使えない場合」の扱いに従う)。
-->
