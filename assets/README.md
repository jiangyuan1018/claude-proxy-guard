# 自定义立绘与图标

默认图标由 `tools/RenderIcons.swift` 绘制，为本项目原创的紫色像素盾牌。

需要替换成你喜欢的角色立绘时，将拥有合法使用权的正方形 PNG 保存为 `assets/Mascot.png`，再运行 `./scripts/build.sh`。
同一张图片会自动用于应用图标、状态面板和菜单栏图标（无损像素插值）。

`assets/Mascot.png` 默认被 Git 忽略。本仓库代码采用 MIT 许可，不分发也不对任何第三方角色立绘授予权利。
