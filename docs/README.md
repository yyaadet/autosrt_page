# AutoSRT

AutoSRT is a powerful desktop application that automatically generates dual language subtitles from video files. Running entirely offline on your local machine, it ensures complete privacy and data security while delivering professional-quality subtitles.

## Features

- 🌐 **Dual Language Subtitles**: Generate subtitles in two languages simultaneously - perfect for language learning and international content
- 🔒 **100% Private & Native**: Runs completely offline on your machine - no internet needed, your videos never leave your computer
- 🌍 **Rich Language Support**: Generate subtitles in multiple languages including Chinese, English, Japanese, Korean, Spanish, Arabic, French, Portuguese, German, Russian, Italian, Thai, Finnish
- 💝 **Free Forever**: All features are completely free - no hidden costs, no subscriptions, no limits
- ⚡ **Fast Local Processing**: Get your subtitles quickly with native processing power, no uploading or waiting for servers
- 📝 **Advanced Subtitle Editor**: Powerful editing tools to perfect your subtitles with search, batch replace, and align with local documents
- 🤖 **Flexible Model Support**: Switch between different LLM models like LLaMA 3, Qwen, Deepseek, QwQ and more easily. Support ollama and OpenAI api format.
- 🎨 **Flexible Video Rendering**: Customize subtitles with adjustable font size, styles, colors, and border styles
- 🔄 **Context-Aware Translation**: Smart subtitle translation that considers the context of the entire conversation

## Screenshots

![Home](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/home.png)

![Processing](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/processing.png)

![Done](https://github.com/yyaadet/autosrt_page/blob/main/screenshots/done.png)


## Installation

MacOS M1 or later is required.


### Install ollama

1. Drag Ollama.app to /Applications. [Ollama](https://ollama.com/).
2. Run Ollama


### Install App

1. Drag AutoSRT-v-xxx.app to /Applications
2. Run AutoSRT

Solve macOS App Opening Issue in One Minute! Fix the error: "Apple cannot verify that 'App Cleaner & Uninstaller' does not contain malware that may harm your Mac or compromise your privacy."

1. Open Terminal (press Command+Space and search for Terminal)
2. Enter these two commands:

```shell
sudo spctl --master-disable

#(navigate to the applications folder)
cd /Applications 

# (use Tab key to auto-complete)
sudo xattr -rd com.apple.quarantine /Applications/AutoSRT.app 
```
3. Enter your user password

Done!

### Install models

If the app downloads models failed or the models are not in the App resources folder, we can download them and install them manually.

You can try download SentenceBERT model manually from [SentenceBERT.mlmodelc.zip](https://github.com/yyaadet/llmsurf/releases/download/v1.0.0/SentenceBERT.mlmodelc.zip).

1. Unzip it. You can see a file named `SentenceBERT.mlmodelc`.
2. Open the Terminal app. If your downloads are in the folder `~/Downloads`, you should run the command: `cd ~/Downloads`
3. Run command in the terminal: `mkdir -p ~/Library/Application\ Support/AutoSRT/Models/SentenceBERT`
4. Run command in the terminal: `cp -rf SentenceBERT.mlmodelc ~/Library/Application\ Support/AutoSRT/Models/SentenceBERT`


Download whisper model from [ggml-large-v3-turbo.bin.zip](https://github.com/yyaadet/autosrt_page/releases/download/v10.0.0/ggml-large-v3-turbo.bin.zip) .

1. Unzip it. You can see a file named `ggml-large-v3-turbo.bin`.
2. Open the Terminal app. If your downloads are in the folder `~/Downloads`, you should run the command: `cd ~/Downloads`
3. Run command in the terminal: `mkdir -p ~/Library/Application\ Support/AutoSRT/Models/ggml-large-v3-turbo`
4. Run command in the terminal: `cp -rf ggml-large-v3-turbo.bin ~/Library/Application\ Support/LLMSurf/Models/ggml-large-v3-turbo`


Of course, you can operate in GUI.

You can also see [https://github.com/yyaadet/autosrt_page/issues/14#issuecomment-3164502050]


### LLM benchmark for translation

- Best: mistral-small3.1:24B

We found if the LLM model has more parameters, more accuracy. The gemma3:4B is obviously better than gemma3:1B. The mistra-small3.1:24B is best than any other LLM models. It can reach at least 90% translation ratio in the most time.

## App Recommendations 

- [Slot Finder: Find your ideal time to study or meeting](https://www.51zhi.com/)
- [AIClips: Find your interesting clips from video with AI-powered intelligence](https://yyaadet.github.io/aiclips/)
- [LLMSurf - AI Agent For macOS](https://github.com/yyaadet/llmsurf) 

![LLMSurf](https://raw.githubusercontent.com/yyaadet/llmsurf/main/images/logo.png)
