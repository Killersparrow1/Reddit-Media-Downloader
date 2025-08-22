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
