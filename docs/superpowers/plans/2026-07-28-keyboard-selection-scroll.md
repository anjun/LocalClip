# 键盘选中项滚动实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 让历史记录的键盘选中项在超出可视区域时，以最小距离自动跟随滚动。

**架构：** 保留 `AppModel.selectedItemID` 作为唯一选中状态。由 `HistoryListSelection` 校验滚动目标 ID，历史列表通过 `ScrollViewReader` 监听选中 ID 变化，并调用不带 anchor 的 `scrollTo`。

**技术栈：** Swift 5.9、SwiftUI、AppKit、Swift Package Manager、自定义 `LocalClipTestRunner`

## 全局约束

- 最低部署版本保持 macOS 13。
- 不新增第三方依赖。
- 不改变键盘路由、搜索、刷新、悬停、点击和粘贴行为。
- 仅在目标 ID 属于当前列表时发起滚动。
- `scrollTo` 不传 anchor，确保只滚动让目标行完整可见所需的最小距离。

---

### 任务 1：滚动目标解析与列表接线

**文件：**
- 修改：`Sources/LocalClipCore/HistoryListSelection.swift`
- 修改：`Sources/LocalClipTestRunner/main.swift:975`
- 修改：`Sources/LocalClipApp/LocalClipApp.swift:262`

**接口：**
- 输入：`selected: String?` 与当前列表的 `[String]`
- 输出：`HistoryListSelection.scrollTargetID(selected:in:) -> String?`
- 使用方：`HistoryPanel.content` 的选中项变化监听

- [ ] **步骤 1：添加失败的回归测试**

在 `runSelectionTests()` 末尾添加：

```swift
expect(
    HistoryListSelection.scrollTargetID(selected: "b", in: ids) == "b",
    "valid selection resolves scroll target"
)
expect(
    HistoryListSelection.scrollTargetID(selected: nil, in: ids) == nil,
    "nil selection has no scroll target"
)
expect(
    HistoryListSelection.scrollTargetID(selected: "gone", in: ids) == nil,
    "stale selection has no scroll target"
)
```

- [ ] **步骤 2：运行测试并确认按预期失败**

运行：

```bash
swift run -c release LocalClipTestRunner
```

预期：编译失败，错误指出 `HistoryListSelection` 不存在
`scrollTargetID(selected:in:)`。

- [ ] **步骤 3：实现最小滚动目标解析**

在 `HistoryListSelection` 中添加：

```swift
/// Selected item id to use as a scroll target, only while it exists in the list.
public static func scrollTargetID(selected: String?, in ids: [String]) -> String? {
    guard let idx = index(of: selected, in: ids) else { return nil }
    return ids[idx]
}
```

- [ ] **步骤 4：运行测试并确认辅助逻辑通过**

运行：

```bash
swift run -c release LocalClipTestRunner
```

预期：输出 `ALL TESTS PASSED`，新增的三个断言均显示 `ok`。

- [ ] **步骤 5：接入 SwiftUI 最小距离滚动**

把非空历史列表包入 `ScrollViewReader`，为每一行添加稳定 ID，并监听选择变化：

```swift
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack(spacing: 0) {
            ForEach(model.items) { item in
                HistoryRow(
                    item: item,
                    isHovered: hoveredID == item.id,
                    isSelected: model.selectedItemID == item.id
                )
                .id(item.id)
                // 保留现有修饰符
            }
        }
        .padding(.horizontal, 8)
    }
    .onChange(of: model.selectedItemID) { selectedID in
        let ids = model.items.map(\.id)
        guard let targetID = HistoryListSelection.scrollTargetID(
            selected: selectedID,
            in: ids
        ) else { return }
        proxy.scrollTo(targetID)
    }
}
```

保留所有现有的 `.contentShape`、悬停、点击、上下文菜单和分隔线代码。

- [ ] **步骤 6：运行完整测试**

运行：

```bash
swift run -c release LocalClipTestRunner
```

预期：输出 `ALL TESTS PASSED`，无失败断言。

- [ ] **步骤 7：构建 release 产品**

运行：

```bash
swift build -c release --product LocalClip
```

预期：构建成功，没有 Swift 编译错误。

- [ ] **步骤 8：检查差异并提交实现**

运行：

```bash
git diff --check
git diff -- Sources/LocalClipCore/HistoryListSelection.swift Sources/LocalClipTestRunner/main.swift Sources/LocalClipApp/LocalClipApp.swift
git add Sources/LocalClipCore/HistoryListSelection.swift Sources/LocalClipTestRunner/main.swift Sources/LocalClipApp/LocalClipApp.swift
git commit -m "fix: keep keyboard selection visible"
```

预期：只包含滚动目标解析、回归测试和历史列表滚动接线。
