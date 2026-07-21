# ゲート検出力の定期抜き打ち検査 — 実施記録

> 手順は [`gate-detection-audit.md`](./gate-detection-audit.md)。新しい回は本ファイル末尾に追記する
> (append-only・記録先固定)。累計の穴が 3 件に達したら B(mutation 自動化)への昇格を検討する。

## 2026-07-21 第 1 回(初回)

- 実施者 / トリガー: 実装者(issue #90 の初回実施として)。以降の定期実施は手順書のトリガー
  (月初の `/goal` 相乗り / assert を足す PR の merge 時)に従う。

### ① 欠陥注入 — 陽性対照 通過

- **対象**: `scripts/reaggregate-has-blocker.py`(選定理由: 選定規則 1 = 負の自己検証を持たない
  assert を検査する script を優先。セク6 の判定表 assert 群は per-assert の負の自己検証を持たず、
  本抜き打ちの主対象カテゴリに当たる)。
- **注入した欠陥**: 比較演算子の反転(類型「比較演算子の反転」)。`reaggregate()` の返り値
  `"has_blocker": blocker_count > 0` を `>= 0` に改変。`blocker_count` は常に 0 以上のため、
  **has_blocker が常に true になる**(clean な PR / findings 空でも「blocker あり」と誤判定し、
  すべての PR の merge を止めてしまう実害のある退行)。
- **smoke の結果**: `bash tests/smoke/run-smoke.sh` が **exit 1 で落ちた**。落とした assert:

  ```
  SMOKE FAIL: (c) code-review 単独 🟡: has_blocker=true (期待: false /
    出力: {"has_blocker": true, "blocker_count": 0, "unknown_source_blockers": [],
    "unknown_severity_blockers": []})
  ```

  セク6 [6/15] の `(c) code-review 単独 🟡`(has_blocker=false を期待する非 blocker ケース)が、
  注入で true に反転したことを検知して落ちた(後続の (d)/(i) 等の false 期待ケースも同様に反応する)。
- **判定**: **陽性対照 通過**。セク6 の判定表 assert は「常に緑」の形骸化ではなく、実際に
  has_blocker の境界反転を捕まえる検出力を持つことを実測した。穴なし(修正 issue 起票なし)。
- **revert**: 済。`git checkout -- scripts/reaggregate-has-blocker.py` で戻し、`git status` が
  clean・112 行目が `blocker_count > 0` に復帰したことを確認。**注入は commit していない。**

### ② merged-PR 照合 — 取り零しなし

- **対象 PR**: #74 `feat(orchestrate): reviewLock に締切機構を追加し手動代行モードの有界停止を明文化する`
  (issue #71)。
- **想定失敗様態**: reviewer / responder への dispatch が reviewLock の締切を超過して **hang する**
  (レビューが永久に返らず orchestrator が停止できない)。締切超過は sink(有界停止)へ落ちるべきで、
  ・hang し続ける ・誤って処理を進める のいずれも退行。加えて `max_retries:0`(reviewLock 用途)では
  締切超過で redispatch を経ず **即 sink** すべき。
- **対応 assert**: **存在する。**
  - セク8 L747-749: `assert_route "(m2) reviewer/timeout (issue #71・reviewLock hang -> 書込なし sink)"`
    / `(m3) responder/timeout` — reviewLock hang(timeout outcome)が書込なし sink へ解決することを固定。
  - セク9 L930: `(r) max_retries:0 (reviewLock 用途・issue #71) -> 締切超過で redispatch を経ず即 sink` —
    max_retries=0 の即 sink 分岐を、既定 N=2 の redispatch 経路(d)/(e)/(f) と対比して固定。
- **判定**: **取り零しなし**。#74 の想定失敗様態(reviewLock hang → sink / max_retries:0 → 即 sink)は
  smoke の対応 assert が存在する。穴なし(修正 issue 起票なし)。

### 累計

- **検出力の穴 累計: 0 件**(3 件で B 昇格検討)。
- 頻度は月次に確定(本回の所要が数分程度と実測できたため。手順書「頻度と記録先」参照)。
