# SET Duell

1v1 SET-Kartenspiel mit Live-Sync über Supabase (Solo oder Multiplayer mit 6-stelligem Lobby-Code).

## Setup
1. Supabase-Projekt anlegen, `supabase-setup.sql` im SQL Editor ausführen.
2. In `config.js` die Project URL und den anon key eintragen.
3. `index.html` hosten (z.B. GitHub Pages) oder lokal öffnen.

## Routen
`/` Start · `/solo` · `/multiplayer` · `/lobby/123456` (tritt direkt der Lobby bei).
Auf Vercel sorgt `vercel.json` (auf GitHub Pages `404.html`) dafür, dass diese Pfade auch beim direkten Aufruf oder Neuladen funktionieren.

## Supabase-Update (einmalig erneut ausführen)
`supabase-setup.sql` im SQL Editor erneut ausführen (idempotent). Es aktiviert
- das Aufräumen alter/leerer Lobbys (Lösch-Policy),
- den Anti-Cheat-Trigger `lobbies_guard`, der jede Zustandsänderung im laufenden Spiel serverseitig prüft.
Ohne das SQL läuft das Spiel weiter, nur ohne diese Absicherungen.
