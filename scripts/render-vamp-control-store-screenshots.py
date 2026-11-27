#!/usr/bin/env python3
"""Frame real Vamp Control window captures without rebuilding or rearranging its UI."""
from PIL import Image, ImageDraw, ImageFont
import argparse, plistlib
from pathlib import Path
import hashlib,json
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures', type=Path, required=True, help='Real, complete app-window PNG captures taken from the running release app; never component renders')
parser.add_argument('--archive', type=Path, required=True, help='The matching Store .xcarchive')
parser.add_argument('--output', type=Path, required=True)
args=parser.parse_args()
root=args.output
raw=args.captures
info=plistlib.loads((args.archive/'Products/Applications/Vamp Control.app/Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.mesutcy.remotedesktop.macclient' or info.get('VampDistributionChannel') != 'app-store':
 parser.error('Expected the Vamp Control store archive')
root.mkdir(parents=True,exist_ok=True)
scenes=[('01-find-your-macs.png',{'en-US':'Find your Macs on your network','tr':'Mac’lerinizi ağınızda bulun'}),('02-session-settings.png',{'en-US':'Set quality and session behavior','tr':'Kalite ve oturum davranışını ayarlayın'}),('03-trusted-hosts.png',{'en-US':'Forget any trusted Mac at any time','tr':'Güvenilen Mac’i istediğiniz zaman unutun'}),('03-vamp-pro.png',{'en-US':'15 free minutes a day. Pro is one payment','tr':'Günde 15 dakika ücretsiz. Pro tek ödeme'})]
scenes=[scene for scene in scenes if (raw/scene[0]).is_file()]
if not scenes: parser.error('No supported real window captures found')
font_path='/System/Library/Fonts/SFNS.ttf'
font=ImageFont.truetype(font_path,40)
label=ImageFont.truetype(font_path,16)
manifest={'product':'Vamp Control','version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'method':'Actual macOS window captures from the running sandboxed release app via CUA. A local runtime copy changes only signing for launch; distribution archive is untouched. Complete captured windows are uniformly scaled and centered on an opaque background with localized captions; no UI elements, content, chrome, tabs, or scroll regions are rearranged.','dimensions':[1440,900],'images':[]}
for locale in ['en-US','tr']:
 out=root/'localizations'/locale;out.mkdir(parents=True,exist_ok=True)
 for name,titles in scenes:
  src=raw/name
  im=Image.open(src).convert('RGB')
  canvas=Image.new('RGB',(1440,900),(18,18,24)); d=ImageDraw.Draw(canvas)
  d.text((720,30),'VAMP CONTROL',font=label,fill=(224,138,181),anchor='mt')
  d.text((720,61),titles[locale],font=font,fill=(245,245,248),anchor='mt')
  factor=min(1280/im.width,748/im.height)
  size=(round(im.width*factor),round(im.height*factor))
  display=im.resize(size,Image.Resampling.LANCZOS)
  canvas.paste(display,((1440-size[0])//2,140+(748-size[1])//2))
  target=out/name;canvas.save(target)
  manifest['images'].append({'locale':locale,'file':name,'rawFile':str(src.resolve()),'rawDimensions':list(im.size),'rawSha256':hashlib.sha256(src.read_bytes()).hexdigest(),'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'md5':hashlib.md5(target.read_bytes()).hexdigest(),'dimensions':[1440,900],'mode':'RGB'})
(root/'source-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
thumbs=[]
for item in manifest['images']:
 im=Image.open(root/'localizations'/item['locale']/item['file']);im.thumbnail((480,300));thumbs.append(im)
sheet=Image.new('RGB',(480*len(scenes),600))
for i,im in enumerate(thumbs):sheet.paste(im,((i%len(scenes))*480,(i//len(scenes))*300))
sheet.save(root/'review-contact-sheet.jpg',quality=94)
print(f'Prepared {len(manifest["images"])} store images from {len(scenes)} complete real app-window captures; originals preserved.')
