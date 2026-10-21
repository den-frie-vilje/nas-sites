# maintenance-page

One static page for any site on the NAS while its real stack is down, in the
bureau's own type and colours. The page picks Danish or English after the
browser's language (`?lang=da` and `?lang=en` override), shows the host name
it was opened on, links the advisory, and carries a contact address. Fonts are
self-hosted (OFL-1.1).

Two ways to put it in front of a site:

**Web Station portal** (sites whose public name is a Web Station portal, so
the certificate and the http to https redirect stay as they are). Copy the
page into the web share once and create a static website for it:

```sh
sudo mkdir -p /volume1/web/maintenance-page
sudo cp -r /volume1/docker/nas-sites/repo/tools/maintenance-page/index.html /volume1/docker/nas-sites/repo/tools/maintenance-page/style.css /volume1/docker/nas-sites/repo/tools/maintenance-page/fonts /volume1/web/maintenance-page/
sudo chmod -R a+rX /volume1/web/maintenance-page
```

Then Web Station, Web Service, Create, static website, name `maintenance-page`,
document root `web/maintenance-page`. Per site: Web Service Portal, edit the
portal, service `maintenance-page`. Reverse the change when the site is back.
A static website answers 200 on `/` and 404 on every other path, so copy the
page as the site's 404 page too (`cp index.html 404.html` in the folder) and
give the portal an error page profile that points at that folder, under Web
Station, Error Page; deep links from bookmarks and notification mails then
show the page as well. Asset paths are absolute for that reason.

**Reverse Proxy rule** (sites on rules, as the client sites are): the
container answers every path with HTTP 503 and `Retry-After`, which keeps the
site indexed as temporarily unavailable.

```sh
sudo docker compose -p maintenance-page -f /volume1/docker/nas-sites/repo/tools/maintenance-page/compose.yml up -d
```

It listens on `127.0.0.1:18099`; set the rule's destination to `localhost`
port 18099, and back when the site returns. `GET /ping` answers 200 for
health checks.
