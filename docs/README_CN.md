# AutoSRT

AutoSRT 是一款功能强大的桌面应用程序，可以自动从视频文件生成双语字幕。所有处理完全在本地计算机上进行，确保了数据隐私和安全性的同时，还能提供专业质量的字幕。

## 功能特点

- 🌐 **双语字幕**：同时生成两种语言的字幕 - 完美适用于语言学习和国际化内容
- 🔒 **100% 私密本地化**：完全离线运行，无需网络，您的视频永远不会离开您的电脑
- 🌍 **丰富的语言支持**：支持多种语言字幕生成：中文、英文、日文、韩文、西班牙语、阿拉伯语、法语、葡萄牙语、德语、俄语、意大利语、泰语、芬兰语
- 💝 **永久免费**：所有功能完全免费 - 无隐藏费用，无订阅，无限制
- ⚡ **快速本地处理**：利用本地处理能力快速生成字幕，无需上传等待服务器
- 📝 **高级字幕编辑器**：强大的编辑工具，支持搜索、批量替换和本地文档对齐
- 🤖 **灵活的模型支持**：轻松切换不同的 LLM 模型，如 LLaMA 3、Qwen、Deepseek、QwQ 等。支持 ollama 和 OpenAI API 格式。
- 🎨 **灵活的视频渲染**：自定义字幕样式，包括字体大小、样式、颜色和边框样式
- 🔄 **上下文感知翻译**：智能字幕翻译，考虑整个对话的上下文，确保更准确自然的翻译

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

## 推荐应用

- [Slot Finder: 找到您理想的学习或会议时间](https://www.51zhi.com/)
- [AIClips: 使用 AI 智能从视频中找到您感兴趣的片段](https://yyaadet.github.io/aiclips/)
- [LLMSurf - macOS 上的 AI 助手](https://github.com/yyaadet/llmsurf)

![LLMSurf](https://raw.githubusercontent.com/yyaadet/llmsurf/main/images/logo.png)

## 致谢

- [有空吗](https://www.51zhi.com/)
