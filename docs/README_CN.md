# AutoSRT

AutoSRT 应用主页。AutoSRT 是一个可以自动从视频文件生成英文和中文字幕的应用程序。

## 功能特点

- 自动从视频文件生成英文字幕
- 自动从视频文件生成中文字幕
- 支持导出 SRT 格式字幕
- 支持导出带字幕的视频
- 支持视频质量控制（1080p、720p、低质量、中等质量、高质量）

## 发布版本

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


一分钟解决Mac APP无法打开！
解决报错：“Apple 无法验证 ‘App Cleaner & Uninstaller’ 是否包含可能危害 Mac 安全或泄漏隐私的恶意软件。”

1.打开command+空格搜索Terminal
2.输入2行代码：

cd /Applications (定位至软件安装位置)
sudo xattr -rd com.apple.quarantine /Applications/xxxxxx.app （可以用Tab键补全）
3.输入用户密码
完成！

## 致谢

- [Slot Finder](https://www.51zhi.com/)
