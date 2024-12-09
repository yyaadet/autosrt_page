# AutoSRT

AutoSRT is a powerful desktop application that automatically generates English and Chinese subtitles from video files. Running entirely offline on your local machine, it ensures complete privacy and data security while delivering professional-quality subtitles.

## Features

- 🔒 **100% Local Processing**: All operations run offline on your machine, ensuring complete privacy
- 🎯 **High-Quality Subtitles**: Automatically generates accurate English and Chinese subtitles
- 💾 **Flexible Export Options**: Export subtitles to SRT format or directly embed them into videos
- 🎥 **Video Quality Control**: Support for various quality settings (1080p, 720p, low, medium, high)
- ⚡ **Fast Processing**: 4x faster rendering compared to previous versions
- 🔐 **Data Security**: Your videos never leave your computer, guaranteeing complete privacy

## Releases


### v3.0.2

- Add app signature, fix macOS security warning


### v3.0.0

- Add llama3.2 model detection
- Add llama3.2 model pulling
- Support Chinese, English, Japanese, Korean, Spanish, Arabic, French, Portuguese, German, Russian, Italian, Korean translation


### v2.0.0

- Accuracy translation of subtitles than before
- Speed up rendering subtitles than before, about 4x faster
- Smaller video file size than before, about 1/10
- More progress bar


## Screenshots

![Home](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/home.png)

![Processing](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/processing.png)

![Done](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/done.png)


## Installation

MacOS M1 or later is required.

1. Install Ollama [https://ollama.com/](https://ollama.com/).
2. Download [AutoSRT](https://github.com/yyaadet/autosrt_page/releases).

Solve macOS App Opening Issue in One Minute!
Fix the error: "Apple cannot verify that 'App Cleaner & Uninstaller' does not contain malware that may harm your Mac or compromise your privacy."

1. Open Terminal (press Command+Space and search for Terminal)
2. Enter these two commands:
```
sudo spctl --master-disable

#(navigate to the applications folder)
cd /Applications 

# (use Tab key to auto-complete)
sudo xattr -rd com.apple.quarantine /Applications/AutoSRT.app 
```
3. Enter your user password

Done!

## Thanks

- [Slot Finder](https://www.51zhi.com/)