#!/bin/bash
# Installation script for Reddit Media Downloader on Fedora

echo "Installing Reddit Media Downloader on Fedora..."

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "Please do not run this script as root."
    exit 1
fi

# Update system
sudo dnf update -y

# Install required packages
sudo dnf install -y python3 python3-pip python3-virtualenv git

# Create project directory
mkdir -p ~/reddit-media-downloader
cd ~/reddit-media-downloader

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install flask flask-cors requests

# Create directory structure
mkdir -p templates static downloads/sfw downloads/nsfw

# Download the main script
cat > reddit_downloader.py << 'EOL'
#!/usr/bin/env python3
"""
Reddit Media Downloader with Browser UI
Supports NSFW content and direct URL downloads
"""

import os
import re
import json
import requests
import logging
import argparse
from pathlib import Path
from flask import Flask, render_template, request, jsonify, send_file, send_from_directory
from flask_cors import CORS
from urllib.parse import urlparse
import threading
import time
from datetime import datetime
import mimetypes

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

# Get the directory where this script is located
SCRIPT_DIR = Path(__file__).parent.absolute()

class RedditMediaDownloader:
    def __init__(self, download_dir="downloads"):
        self.download_dir = SCRIPT_DIR / download_dir
        self.download_dir.mkdir(exist_ok=True)
        
        # Create subdirectories
        self.sfw_dir = self.download_dir / "sfw"
        self.nsfw_dir = self.download_dir / "nsfw"
        self.sfw_dir.mkdir(exist_ok=True)
        self.nsfw_dir.mkdir(exist_ok=True)
        
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 RedditMediaDownloader/1.0'
        })

    def extract_reddit_id(self, url):
        """Extract Reddit post ID from URL"""
        patterns = [
            r'reddit\.com/r/\w+/comments/(\w+)',
            r'reddit\.com/comments/(\w+)',
            r'redd\.it/(\w+)'
        ]
        
        for pattern in patterns:
            match = re.search(pattern, url)
            if match:
                return match.group(1)
        return None

    def get_reddit_data(self, post_id):
        """Fetch post data from Reddit API"""
        url = f"https://www.reddit.com/comments/{post_id}.json"
        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()
            return response.json()
        except Exception as e:
            logger.error(f"Error fetching Reddit data: {e}")
            return None

    def extract_media_urls(self, post_data, is_nsfw=False):
        """Extract media URLs from Reddit post data"""
        if not post_data or len(post_data) < 1:
            return []
        
        post = post_data[0]['data']['children'][0]['data']
        media_urls = []
        
        # Check for gallery posts
        if 'gallery_data' in post and 'media_metadata' in post:
            for item in post['gallery_data']['items']:
                media_id = item['media_id']
                if media_id in post['media_metadata']:
                    metadata = post['media_metadata'][media_id]
                    if metadata['status'] == 'valid':
                        if metadata['e'] == 'Image':
                            url = metadata['s']['u']
                            media_urls.append(url.replace('&amp;', '&'))
        
        # Check for single image/video posts
        elif 'url' in post:
            url = post['url']
            
            # Handle imgur links
            if 'imgur.com' in url:
                if '/a/' in url or '/gallery/' in url:
                    # Handle imgur albums (would need imgur API)
                    pass
                else:
                    # Single imgur image
                    if not url.endswith(('.jpg', '.png', '.gif')):
                        url += '.jpg'
                    media_urls.append(url)
            
            # Handle reddit media
            elif 'redd.it' in url or 'reddit.com' in url:
                media_urls.append(url)
            
            # Handle direct image links
            elif url.endswith(('.jpg', '.jpeg', '.png', '.gif', '.gifv', '.mp4', '.webm')):
                media_urls.append(url)
            
            # Handle v.redd.it videos
            elif 'v.redd.it' in url:
                # Try to get the highest quality video
                try:
                    video_data = self.get_vreddit_data(post['id'])
                    if video_data and 'fallback_url' in video_data:
                        media_urls.append(video_data['fallback_url'])
                except:
                    media_urls.append(url)
        
        return media_urls

    def get_vreddit_data(self, post_id):
        """Get video data for v.redd.it posts"""
        url = f"https://www.reddit.com/video/{post_id}"
        try:
            response = self.session.get(url, timeout=30)
            html = response.text
            
            # Extract JSON data from HTML
            pattern = r'<script id="data">window\.___r = (.*?);</script>'
            match = re.search(pattern, html)
            if match:
                data = json.loads(match.group(1))
                return data.get('video', {})
        except Exception as e:
            logger.error(f"Error fetching v.redd.it data: {e}")
        return None

    def download_media(self, url, filename, is_nsfw=False):
        """Download a single media file"""
        try:
            response = self.session.get(url, stream=True, timeout=60)
            response.raise_for_status()
            
            # Determine download directory
            download_path = self.nsfw_dir if is_nsfw else self.sfw_dir
            
            # Ensure filename has proper extension
            if not any(filename.lower().endswith(ext) for ext in ['.jpg', '.jpeg', '.png', '.gif', '.mp4', '.webm']):
                content_type = response.headers.get('content-type', '')
                if 'image/jpeg' in content_type:
                    filename += '.jpg'
                elif 'image/png' in content_type:
                    filename += '.png'
                elif 'image/gif' in content_type:
                    filename += '.gif'
                elif 'video/mp4' in content_type:
                    filename += '.mp4'
                elif 'video/webm' in content_type:
                    filename += '.webm'
            
            file_path = download_path / filename
            
            with open(file_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
            
            return str(file_path.relative_to(SCRIPT_DIR)), None
        except Exception as e:
            return None, str(e)

    def download_from_url(self, reddit_url, is_nsfw=False):
        """Download media from Reddit URL"""
        try:
            post_id = self.extract_reddit_id(reddit_url)
            if not post_id:
                return [], "Invalid Reddit URL"
            
            post_data = self.get_reddit_data(post_id)
            if not post_data:
                return [], "Failed to fetch post data"
            
            # Check if post is actually NSFW
            post = post_data[0]['data']['children'][0]['data']
            actual_nsfw = post.get('over_18', False)
            is_nsfw = is_nsfw or actual_nsfw
            
            media_urls = self.extract_media_urls(post_data, is_nsfw)
            if not media_urls:
                return [], "No media found in post"
            
            downloaded_files = []
            errors = []
            
            for i, media_url in enumerate(media_urls):
                filename = f"{post_id}_{i+1}_{int(time.time())}"
                file_path, error = self.download_media(media_url, filename, is_nsfw)
                
                if file_path:
                    downloaded_files.append({
                        'url': media_url,
                        'path': file_path,
                        'filename': os.path.basename(file_path)
                    })
                elif error:
                    errors.append(f"Failed to download {media_url}: {error}")
            
            return downloaded_files, "; ".join(errors) if errors else None
            
        except Exception as e:
            return [], f"Error: {str(e)}"

# Global downloader instance
downloader = RedditMediaDownloader()

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/static/<path:filename>')
def serve_static(filename):
    return send_from_directory(SCRIPT_DIR / 'static', filename)

@app.route('/api/download', methods=['POST'])
def api_download():
    data = request.json
    reddit_url = data.get('url', '').strip()
    is_nsfw = data.get('nsfw', False)
    
    if not reddit_url:
        return jsonify({'success': False, 'error': 'No URL provided'})
    
    logger.info(f"Download request: {reddit_url} (NSFW: {is_nsfw})")
    
    downloaded_files, error = downloader.download_from_url(reddit_url, is_nsfw)
    
    if downloaded_files:
        return jsonify({
            'success': True,
            'files': downloaded_files,
            'message': f'Downloaded {len(downloaded_files)} files successfully'
        })
    else:
        return jsonify({
            'success': False,
            'error': error or 'Failed to download media'
        })

@app.route('/api/files')
def api_files():
    """List downloaded files"""
    files = []
    
    for dir_path in [downloader.sfw_dir, downloader.nsfw_dir]:
        for file in dir_path.glob('*'):
            if file.is_file():
                files.append({
                    'name': file.name,
                    'path': str(file.relative_to(SCRIPT_DIR)),
                    'size': file.stat().st_size,
                    'modified': file.stat().st_mtime,
                    'is_nsfw': 'nsfw' in str(file.parent)
                })
    
    # Sort by modification time (newest first)
    files.sort(key=lambda x: x['modified'], reverse=True)
    
    return jsonify({'files': files})

@app.route('/api/download-file/<path:filename>')
def download_file(filename):
    """Download a specific file"""
    file_path = SCRIPT_DIR / filename
    if file_path.exists() and file_path.is_file():
        return send_file(file_path, as_attachment=True)
    return jsonify({'error': 'File not found'}), 404

@app.route('/api/delete-file/<path:filename>', methods=['DELETE'])
def delete_file(filename):
    """Delete a specific file"""
    try:
        file_path = SCRIPT_DIR / filename
        if file_path.exists() and file_path.is_file():
            file_path.unlink()
            return jsonify({'success': True})
        return jsonify({'error': 'File not found'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500

def run_server(host='0.0.0.0', port=5000, debug=True):
    """Run the Flask server"""
    logger.info(f"Starting Reddit Media Downloader server on http://{host}:{port}")
    logger.info(f"Download directory: {downloader.download_dir}")
    app.run(host=host, port=port, debug=debug, threaded=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Reddit Media Downloader with Web UI')
    parser.add_argument('--host', default='0.0.0.0', help='Host to run server on')
    parser.add_argument('--port', type=int, default=5000, help='Port to run server on')
    parser.add_argument('--download-dir', default='downloads', help='Directory to save downloads')
    parser.add_argument('--no-debug', action='store_true', help='Disable debug mode')
    
    args = parser.parse_args()
    
    # Update download directory
    downloader = RedditMediaDownloader(args.download_dir)
    
    run_server(host=args.host, port=args.port, debug=not args.no_debug)
EOL

# Create HTML template
mkdir -p templates
cat > templates/index.html << 'EOL'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Reddit Media Downloader</title>
    <link rel="stylesheet" href="/static/style.css">
</head>
<body>
    <div class="container">
        <header>
            <h1>Reddit Media Downloader</h1>
            <p class="subtitle">Download media from Reddit posts including NSFW content</p>
        </header>

        <div class="main-content">
            <div class="download-section">
                <h2>Download Media</h2>
                <form id="downloadForm">
                    <div class="form-group">
                        <label for="redditUrl">Reddit Post URL:</label>
                        <input type="url" id="redditUrl" placeholder="https://www.reddit.com/r/..." required>
                    </div>
                    
                    <div class="form-group">
                        <div class="checkbox-group">
                            <input type="checkbox" id="nsfwCheck">
                            <label for="nsfwCheck">NSFW Content</label>
                        </div>
                    </div>
                    
                    <button type="submit" id="downloadBtn">Download Media</button>
                </form>

                <div class="loading" id="loading">
                    <div class="spinner"></div>
                    <p>Downloading media...</p>
                </div>

                <div class="status" id="status"></div>
            </div>

            <div class="files-section">
                <h2>Downloaded Files</h2>
                <button onclick="loadFiles()" style="margin-bottom: 20px;">Refresh Files</button>
                <div class="file-list" id="fileList">
                    <p>No files downloaded yet.</p>
                </div>
            </div>
        </div>
    </div>

    <script>
        const apiBase = '/api';
        
        document.getElementById('downloadForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            
            const url = document.getElementById('redditUrl').value;
            const isNsfw = document.getElementById('nsfwCheck').checked;
            const downloadBtn = document.getElementById('downloadBtn');
            const loading = document.getElementById('loading');
            const status = document.getElementById('status');
            
            // Validate URL
            if (!url.includes('reddit.com') && !url.includes('redd.it')) {
                showStatus('Please enter a valid Reddit URL', 'error');
                return;
            }
            
            downloadBtn.disabled = true;
            loading.style.display = 'block';
            status.style.display = 'none';
            
            try {
                const response = await fetch(`${apiBase}/download`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        url: url,
                        nsfw: isNsfw
                    })
                });
                
                const data = await response.json();
                
                if (data.success) {
                    showStatus(`Success! Downloaded ${data.files.length} file(s)`, 'success');
                    document.getElementById('redditUrl').value = '';
                    loadFiles();
                } else {
                    showStatus(`Error: ${data.error}`, 'error');
                }
            } catch (error) {
                showStatus('Network error. Please try again.', 'error');
            } finally {
                downloadBtn.disabled = false;
                loading.style.display = 'none';
            }
        });
        
        function showStatus(message, type) {
            const status = document.getElementById('status');
            status.textContent = message;
            status.className = `status ${type}`;
            status.style.display = 'block';
        }
        
        async function loadFiles() {
            const fileList = document.getElementById('fileList');
            fileList.innerHTML = '<p>Loading files...</p>';
            
            try {
                const response = await fetch(`${apiBase}/files`);
                const data = await response.json();
                
                if (data.files.length === 0) {
                    fileList.innerHTML = '<p>No files downloaded yet.</p>';
                    return;
                }
                
                fileList.innerHTML = '';
                data.files.forEach(file => {
                    const fileItem = document.createElement('div');
                    fileItem.className = 'file-item';
                    
                    const fileInfo = document.createElement('div');
                    fileInfo.className = 'file-info';
                    
                    const fileName = document.createElement('div');
                    fileName.className = 'file-name';
                    fileName.textContent = file.name;
                    if (file.is_nsfw) {
                        const nsfwBadge = document.createElement('span');
                        nsfwBadge.className = 'nsfw-badge';
                        nsfwBadge.textContent = 'NSFW';
                        fileName.appendChild(nsfwBadge);
                    }
                    
                    const fileSize = document.createElement('div');
                    fileSize.className = 'file-size';
                    fileSize.textContent = formatFileSize(file.size);
                    
                    fileInfo.appendChild(fileName);
                    fileInfo.appendChild(fileSize);
                    
                    const fileActions = document.createElement('div');
                    fileActions.className = 'file-actions';
                    
                    const downloadBtn = document.createElement('button');
                    downloadBtn.className = 'btn-download';
                    downloadBtn.textContent = 'Download';
                    downloadBtn.onclick = () => window.open(`${apiBase}/download-file/${file.path}`, '_blank');
                    
                    const deleteBtn = document.createElement('button');
                    deleteBtn.className = 'btn-delete';
                    deleteBtn.textContent = 'Delete';
                    deleteBtn.onclick = () => deleteFile(file.path);
                    
                    fileActions.appendChild(downloadBtn);
                    fileActions.appendChild(deleteBtn);
                    
                    fileItem.appendChild(fileInfo);
                    fileItem.appendChild(fileActions);
                    
                    fileList.appendChild(fileItem);
                });
            } catch (error) {
                fileList.innerHTML = '<p>Error loading files.</p>';
            }
        }
        
        async function deleteFile(filepath) {
            if (!confirm('Are you sure you want to delete this file?')) {
                return;
            }
            
            try {
                const response = await fetch(`${apiBase}/delete-file/${filepath}`, {
                    method: 'DELETE'
                });
                
                const data = await response.json();
                
                if (data.success) {
                    showStatus('File deleted successfully', 'success');
                    loadFiles();
                } else {
                    showStatus('Error deleting file', 'error');
                }
            } catch (error) {
                showStatus('Network error', 'error');
            }
        }
        
        function formatFileSize(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        // Load files on page load
        document.addEventListener('DOMContentLoaded', loadFiles);
    </script>
</body>
</html>
EOL

# Create CSS file
mkdir -p static
cat > static/style.css << 'EOL'
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    min-height: 100vh;
    padding: 20px;
}

.container {
    max-width: 1200px;
    margin: 0 auto;
    background: white;
    border-radius: 15px;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
    overflow: hidden;
}

header {
    background: linear-gradient(135deg, #ff6b6b 0%, #ee5a24 100%);
    color: white;
    padding: 30px;
    text-align: center;
}

h1 {
    font-size: 2.5em;
    margin-bottom: 10px;
}

.subtitle {
    font-size: 1.1em;
    opacity: 0.9;
}

.main-content {
    padding: 30px;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 30px;
}

@media (max-width: 768px) {
    .main-content {
        grid-template-columns: 1fr;
    }
}

.download-section, .files-section {
    background: #f8f9fa;
    padding: 25px;
    border-radius: 10px;
    border: 1px solid #e9ecef;
}

h2 {
    color: #2d3436;
    margin-bottom: 20px;
    font-size: 1.8em;
}

.form-group {
    margin-bottom: 20px;
}

label {
    display: block;
    margin-bottom: 8px;
    font-weight: 600;
    color: #2d3436;
}

input[type="url"], input[type="text"] {
    width: 100%;
    padding: 12px;
    border: 2px solid #ddd;
    border-radius: 8px;
    font-size: 16px;
    transition: border-color 0.3s;
}

input[type="url"]:focus, input[type="text"]:focus {
    outline: none;
    border-color: #667eea;
}

.checkbox-group {
    display: flex;
    align-items: center;
    gap: 10px;
}

.checkbox-group input[type="checkbox"] {
    width: 18px;
    height: 18px;
}

button {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: white;
    border: none;
    padding: 15px 30px;
    border-radius: 8px;
    font-size: 16px;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.2s;
    width: 100%;
}

button:hover {
    transform: translateY(-2px);
}

button:disabled {
    opacity: 0.6;
    cursor: not-allowed;
    transform: none;
}

.status {
    margin-top: 20px;
    padding: 15px;
    border-radius: 8px;
    display: none;
}

.status.success {
    background: #d4edda;
    color: #155724;
    border: 1px solid #c3e6cb;
    display: block;
}

.status.error {
    background: #f8d7da;
    color: #721c24;
    border: 1px solid #f5c6cb;
    display: block;
}

.status.info {
    background: #d1ecf1;
    color: #0c5460;
    border: 1px solid #bee5eb;
    display: block;
}

.file-list {
    max-height: 400px;
    overflow-y: auto;
}

.file-item {
    background: white;
    padding: 15px;
    margin-bottom: 10px;
    border-radius: 8px;
    border: 1px solid #ddd;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.file-info {
    flex: 1;
}

.file-name {
    font-weight: 600;
    color: #2d3436;
}

.file-size {
    color: #6c757d;
    font-size: 0.9em;
}

.file-actions {
    display: flex;
    gap: 10px;
}

.btn-download, .btn-delete {
    padding: 8px 15px;
    border: none;
    border-radius: 5px;
    cursor: pointer;
    font-size: 14px;
}

.btn-download {
    background: #28a745;
    color: white;
}

.btn-delete {
    background: #dc3545;
    color: white;
}

.nsfw-badge {
    background: #ff4757;
    color: white;
    padding: 3px 8px;
    border-radius: 12px;
    font-size: 0.8em;
    margin-left: 10px;
}

.loading {
    display: none;
    text-align: center;
    margin: 20px 0;
}

.spinner {
    border: 4px solid #f3f3f3;
    border-top: 4px solid #667eea;
    border-radius: 50%;
    width: 40px;
    height: 40px;
    animation: spin 1s linear infinite;
    margin: 0 auto;
}

@keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
}
EOL

# Create requirements file
cat > requirements.txt << 'EOL'
Flask==2.3.3
Flask-CORS==4.0.0
requests==2.31.0
EOL

# Make the script executable
chmod +x reddit_downloader.py

# Create a systemd service file
cat > reddit-downloader.service << EOL
[Unit]
Description=Reddit Media Downloader
After=network.target

[Service]
User=$USER
WorkingDirectory=$HOME/reddit-media-downloader
Environment=PATH=$HOME/reddit-media-downloader/venv/bin
ExecStart=$HOME/reddit-media-downloader/venv/bin/python reddit_downloader.py --host 0.0.0.0 --port 5000 --no-debug
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

echo "Installation complete!"
echo ""
echo "To start the server manually:"
echo "  cd ~/reddit-media-downloader"
echo "  source venv/bin/activate"
echo "  python reddit_downloader.py"
echo ""
echo "To set up as a system service:"
echo "  sudo cp ~/reddit-media-downloader/reddit-downloader.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable reddit-downloader.service"
echo "  sudo systemctl start reddit-downloader.service"
echo ""
echo "The application will be available at: http://localhost:5000"
