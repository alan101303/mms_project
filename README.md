# Küchenstimme

Ein deutschsprachiger Kochassistent für Android. Rezepte werden lokal aus
`assets/recipes.json` geladen. Auf der Startseite kann ein Rezept aus der Liste
oder per Sprache geöffnet werden. Über das Hilfesymbol auf der Startseite sind
die verfügbaren Sprachbefehle jederzeit erreichbar. Die separate Kochansicht
zeigt jeweils einen Schritt und bietet Touch-Symbole sowie ein Mikrofon für die
Sprachsteuerung. Die Spracherkennung ist auf Deutsch (`de_DE`) eingestellt.

## Starten

```sh
flutter pub get
flutter run
```

Beim ersten Start der Sprachsteuerung fragt Android nach Mikrofonzugriff.
Die Spracherkennung benötigt einen auf dem Gerät verfügbaren deutschen
Erkennungsdienst; eine Internetverbindung kann je nach Android-Dienst nötig
sein.

## Sprachbefehle

- „Weiter“ / „Fortsetzen“ – nächsten Schritt anzeigen oder pausierte Anleitung fortsetzen
- „Zurück“ – vorherigen Schritt anzeigen
- „Nochmal“ / „Wiederholen“ – aktuellen Schritt erneut vorlesen
- „Zutaten“ – Zutatenliste öffnen
- „Timer fünf Minuten“ – Küchentimer starten (1 bis 240 Minuten)
- „Pause“ – Anleitung pausieren
- Auf der Startseite einen Rezeptnamen oder „Rezept zwei“ sagen – Rezept öffnen

Das Mikrofon am unteren Rand der Kochansicht zeigt den Zuhörstatus und den
erkannten Text an. Erkannte Sprache wird mit einem kurzen Systemton bestätigt.
Bei unklaren oder nicht erkannten Befehlen gibt die App Rückmeldung. Alle
Kochaktionen bleiben über die Symbol-Schaltflächen jederzeit per Touch
erreichbar; „Rückgängig“ stellt die letzte Rezept-, Schritt-, Pause- oder
Timeraktion wieder her.
