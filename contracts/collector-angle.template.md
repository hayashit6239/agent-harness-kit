---
# 観点の識別子(kebab-case・全 angle でユニーク)。finder のラベルと findings の分類に使う。
id: my-angle
# 人間可読な観点名(日本語可)。作業レポート・ダッシュボードに表示される。
label: 観点の名前
# (任意・パターン A)この観点を skill に委譲する場合の skill 名。
# 指定すると finder は general-purpose で起動したうえで Skill ツールでこの skill を起動して従う。
# 省略時は下の本文の指示だけで探す。判定を伴う skill は置かない(収集専任のみ)。
# skill: architecture-review
# (任意)false でこの観点を無効化(既定 true)。kit 同梱観点を導入先で切りたいとき。
# enabled: true
---

<!--
この下に finder への指示(何を探すか)を 1〜2 文で書く。規約:
- finder は general-purpose で起動される(fork は使わない・機構 = strategy.md 側が保証)。
- 出力は必ず contracts/findings.schema.json の形 {file, line, summary, failure_scenario}。
- severity・合否は付けない(判定は pr reviewer が独立に行う = doer≠judge)。
- diff で新規追加/変更された箇所に限定し、既存コードの一般論は挙げない。
- skill: を指定した場合、機構側が「まず Skill ツールで <skill> を起動して従い」を先頭に補う。
-->
この観点が探すものをここに 1〜2 文で書く。
