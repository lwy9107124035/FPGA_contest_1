from PIL import Image, ImageDraw, ImageFont
f = ImageFont.truetype(r"C:\Windows\Fonts\simsun.ttc", 16)
for ch in "警撤台":
    img = Image.new("L", (16, 16), 0)
    d = ImageDraw.Draw(img)
    d.text((0, 0), ch, fill=255, font=f)
    print("=== %s ===" % ch)
    for y in range(16):
        print("".join("#" if img.getpixel((x, y)) >= 128 else "." for x in range(16)))
    print()
