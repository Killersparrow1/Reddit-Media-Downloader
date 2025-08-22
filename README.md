# Reddit Media Downloader

[![Screenshot.png](https://i.postimg.cc/26JffJKz/Screenshot.png)](https://postimg.cc/gXv7VMp5)

A Python-based web application to download media from Reddit posts, including NSFW content.

## Features

- Web-based UI for easy access
- Support for NSFW content
- Download by Reddit post URL
- Organized file storage (SFW/NSFW folders)
- File management (view, download, delete)
- Responsive design

## Installation on Fedora

1. Clone or download this repository  
2. Make the installation script executable:
   ```bash
   chmod +x install.sh
   ```
3. Run the installation script:
   ```bash
   ./install.sh
   ```

## Usage

### Manual Start
```bash
cd ~/reddit-media-downloader
source venv/bin/activate
python reddit_downloader.py
```

### As a System Service
```bash
sudo cp ~/reddit-media-downloader/reddit-downloader.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable reddit-downloader.service
sudo systemctl start reddit-downloader.service
```

### Access the Application
Open your web browser and navigate to:  
```
http://localhost:5000
```

### How to Use
- Paste a Reddit post URL in the input field  
- Check the "NSFW Content" box if the post contains NSFW material  
- Click "Download Media"  
- View and manage downloaded files in the "Downloaded Files" section  

## Directory Structure
```
reddit-media-downloader/
├── reddit_downloader.py     # Main application
├── templates/
│   └── index.html           # Web interface
├── static/
│   └── style.css            # Stylesheet
├── downloads/
│   ├── sfw/                 # SFW downloads
│   └── nsfw/                # NSFW downloads
├── requirements.txt         # Python dependencies
├── install.sh               # Installation script
└── README.md                # This file
```

## Notes
- The application will create a downloads directory with sfw and nsfw subdirectories  
- Downloaded files are organized by content type automatically  
- The web interface is accessible from any device on your network  

## Troubleshooting
If you encounter issues:

1. Check if all dependencies are installed:
   ```bash
   pip install -r requirements.txt
   ```
2. Ensure the application has write permissions to the download directory  
3. Check the application logs for error messages  

---

## Installation and Usage (Quick Steps)

1. Save all these files in a directory called `reddit-media-downloader`  
2. Make the installation script executable:
   ```bash
   chmod +x install.sh
   ```
3. Run the installation:
   ```bash
   ./install.sh
   ```
4. Start the application:
   ```bash
   cd ~/reddit-media-downloader
   source venv/bin/activate
   python reddit_downloader.py
   ```
5. Open your browser and go to `http://localhost:5000`  

The application will create the following directory structure:
```
~/reddit-media-downloader/
├── reddit_downloader.py
├── templates/
│   └── index.html
├── static/
│   └── style.css
├── downloads/
│   ├── sfw/
│   └── nsfw/
├── requirements.txt
├── install.sh
└── README.md
```

All downloaded media will be saved in the downloads directory, organized into sfw and nsfw subfolders.

---
## Acknowledgements

Special thanks to DeepSeek AI and ChatGPT AI for their assistance and support in building and documenting this project.
