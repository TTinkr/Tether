#!/usr/bin/env python3
"""Regenerate the installer artwork; requires Pillow and macOS Helvetica fonts.
The application and Applications icons are real Finder items, not artwork.
"""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFont
root = Path(__file__).resolve().parent
for scale in (1,2):
    image=Image.new('RGB',(640*scale,420*scale),'#F6F5F1')
    draw=ImageDraw.Draw(image)
    def text(y,value,size,color,bold=False):
        font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',size*scale,index=1 if bold else 0)
        box=draw.textbbox((0,0),value,font=font)
        draw.text(((640*scale-(box[2]-box[0]))/2,y*scale-box[1]),value,font=font,fill=color)
    text(43,'Install Tokens',28,'#262B28',True)
    text(85,'Drag Tokens to Applications.',16,'#5D645F')
    draw.line([(294*scale,220*scale),(346*scale,220*scale)],fill='#CC4339',width=3*scale)
    draw.line([(337*scale,211*scale),(347*scale,220*scale),(337*scale,229*scale)],fill='#CC4339',width=3*scale,joint='curve')
    draw.line([(48*scale,333*scale),(592*scale,333*scale)],fill='#DFE1DA',width=scale)
    text(358,'Then open Tokens from Applications.',13,'#5D645F')
    png=root/f'background@{scale}x.png';image.save(png)
    subprocess.run(['/usr/bin/sips','-s','format','tiff',str(png),'--out',str(root/f'background@{scale}x.tiff')],check=True,capture_output=True)
subprocess.run(['/usr/bin/tiffutil','-cathidpicheck',str(root/'background@1x.tiff'),str(root/'background@2x.tiff'),'-out',str(root/'background.tiff')],check=True)
for scale in (1,2):(root/f'background@{scale}x.tiff').unlink()
