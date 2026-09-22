# urali update 006 — image studio for your designer

Upload these to the top level of `anup-aws/urali-site` (replace existing files with the same name):

    update-urali-006.sh   media_server.py   studio.html   admin.html   index.html
    favicon.png   favicon-180.png   favicon-32.png   og-image.jpg
    original-hero.webp   original-box-classic.webp   original-box-duo.webp
    original-box-tin.webp   original-box-chakka.webp
    update-urali-005.sh   (small fix; replace the old one)

Run update 005 first if you haven't yet, then:

    curl -fsSL "https://raw.githubusercontent.com/anup-aws/urali-site/main/update-urali-006.sh?r=$RANDOM" -o /root/update-urali-006.sh && bash /root/update-urali-006.sh 2>&1 | tee /root/urali-update-006.log

At the end it prints a studio login for **designer**. Send it to him privately.
Your own admin login works in the studio too.

To give someone else a studio login:  `bash /root/update-urali-006.sh --add-user ravi`
To replace the designer's password:   `bash /root/update-urali-006.sh --add-user designer`

## What your designer can do at uralichips.com/studio/

Each picture on the site — the top image, the four product boxes, the browser-tab icon, and the
WhatsApp link preview — has one row of versions:

    Original  →  Version 1  →  Version 2  →  …  →  + Add new

The original is the drawing that's on the site today, shown as a real picture. Tapping any tile
makes it live. "Add new" uploads another version and makes it live. Dragging a file onto a card
does the same. Going back to the original is just tapping it. Nothing is ever deleted.

Box photos should be landscape, 3:2 (1200 × 800 px), with the subject in the middle — phones
trim the sides slightly. The top image works best at 1600 × 1000 px.

He cannot see orders, customers or anything in the admin page.

## How it's kept safe and fast

- Every upload is decoded and re-encoded on the server. Only pixels are saved — anything else
  hiding in a file is dropped. PNG, JPG and WebP only, up to 8 MB.
- Photos are resized (1600 px for the top image, 1200 px for boxes) and saved as WebP, so a
  6 MB phone photo becomes a few hundred KB.
- Nothing is ever deleted. Every version is kept, and every change is logged with who made it
  in `/var/lib/urali-media/audit.log`.
- The service runs as its own user, can only write to the images folder, and is reachable only
  through Nginx behind a login.
