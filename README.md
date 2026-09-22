# urali update 006 — image studio for your designer

Upload these to the top level of `anup-aws/urali-site` (replace existing files with the same name):

    update-urali-006.sh   media_server.py   studio.html   admin.html   index.html
    favicon.png   favicon-180.png   favicon-32.png   og-image.jpg
    update-urali-005.sh   (small fix; replace the old one)

Run update 005 first if you haven't yet, then:

    curl -fsSL "https://raw.githubusercontent.com/anup-aws/urali-site/main/update-urali-006.sh?r=$RANDOM" -o /root/update-urali-006.sh && bash /root/update-urali-006.sh 2>&1 | tee /root/urali-update-006.log

At the end it prints a studio login for **designer**. Send it to him privately.
Your own admin login works in the studio too.

To give someone else a studio login:  `bash /root/update-urali-006.sh --add-user ravi`
To replace the designer's password:   `bash /root/update-urali-006.sh --add-user designer`

## What your designer can do at uralichips.com/studio/

Replace the picture at the top of the page, each of the four product boxes, the browser-tab
icon, and the image shown when the link is shared on WhatsApp. He can drag a file onto a card,
edit its description, switch back to any earlier upload, or return to the original drawing.

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
