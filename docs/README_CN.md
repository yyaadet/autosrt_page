# AutoSRT

AutoSRT 是一款功能强大的桌面应用程序，可以自动从视频文件生成英文和中文字幕。所有处理完全在本地计算机上进行，确保了数据隐私和安全性的同时，还能提供专业质量的字幕。

## 功能特点

- 🔒 **100% 本地处理**：所有操作都在您的计算机上离线运行，确保完全的隐私安全
- 🎯 **高质量字幕**：自动生成准确的英文和中文字幕
- 💾 **灵活的导出选项**：支持导出 SRT 格式字幕或直接嵌入到视频中
- 🎥 **视频质量控制**：支持多种质量设置（1080p、720p、低质量、中等质量、高质量）
- ⚡ **快速处理**：与之前版本相比，渲染速度提升4倍
- 🔐 **数据安全**：您的视频永远不会离开您的计算机，保证完全的隐私

## 发布版本

### v7.1.0 (2024-12-18)

- 修复字幕对齐问题
- 支持泰语翻译
- 改进视频中的字幕效果

### v3.0.2

- 添加应用签名，修复 macOS 安全警告

### v2.0.0

- 字幕翻译准确度更高
- 字幕渲染速度提升，大约快4倍
- 视频文件体积更小，约为原来的1/10
- 更多进度条显示

## 截图展示

![首页](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/home.png)

![处理中](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/processing.png)

![完成](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/done.png)

## 安装说明

需要 MacOS M1 或更新版本。

1. 安装 Ollama [https://ollama.com/](https://ollama.com/)
2. 下载 [AutoSRT](https://github.com/yyaadet/autosrt_page/releases)

一分钟解决 macOS 应用打开问题！
修复错误："Apple 无法验证此 App 是否包含恶意软件，可能会损害您的 Mac 或泄露您的隐私。"

1. 打开终端（按 Command+Space 并搜索"终端"）
2. 输入以下两个命令：
```
sudo spctl --master-disable

# (进入应用程序文件夹)
cd /Applications 

# (使用 Tab 键自动补全)
sudo xattr -rd com.apple.quarantine /Applications/AutoSRT.app 
```
3. 输入您的用户密码

完成！

## 致谢

- [Slot Finder](https://www.51zhi.com/)
