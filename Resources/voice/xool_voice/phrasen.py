"""The library of bridge phrases: German conversation starters, by situation.

Each group is a situation the assistant can be in when the real answer is not
ready yet. `bruecken.FillerBank` turns them into audio once, keeps the audio
on disk and plays one at the right moment, never the same one twice in a row.
Keep them short: they cover a second or two, then the real answer follows.
"""

from __future__ import annotations

PHRASES: dict[str, list[str]] = {
    # -- a question is asked ---------------------------------------------------------------
    "frage": [
        "Hm, gute Frage.", "Moment, ich überlege kurz.", "Lass mich kurz nachdenken.",
        "Hmm.", "Gute Frage.", "Spannende Frage.", "Hm, warte mal.", "Oh, gute Frage.",
        "Moment.", "Hm, lass mich überlegen.", "Ah, okay.", "Na ja, mal sehen.",
        "Hm, ja.", "Ja, also.", "Okay, Moment.", "Hmm, interessant.", "Also, hm.",
        "Hm, da muss ich kurz überlegen.", "Ah, das ist eine gute Frage.", "Ähm, ja.",
        "Mal überlegen.", "Da muss ich kurz nachdenken.", "Hm, das ist gar nicht so einfach.",
        "Einen Moment, bitte.", "Okay, lass mich kurz sammeln.", "Interessante Frage, Moment.",
        "Hm, wie sag ich das am besten.", "Gleich, ich ordne kurz meine Gedanken.",
        "Also, die Antwort ist nicht ganz kurz.", "Ah, da fällt mir was ein.",
    ],
    # -- an order ----------------------------------------------------------------------------
    "befehl": [
        "Okay.", "Alles klar.", "Mach ich.", "Klar.", "Geht klar.", "Gerne.",
        "Okay, mach ich.", "Jawohl.", "Ja, klar.", "Sofort.", "Okay, gerne.",
        "Alles klar, Moment.", "Kein Problem.", "Klar, mach ich.", "In Ordnung.",
        "Okay, einen Moment.", "Gut, mach ich.", "Ja, gerne.", "Wird gemacht.", "Okidoki.",
        "Bin dran.", "Ich kümmere mich drum.", "Verstanden, ich fange an.", "Läuft.",
        "Ich mach das gleich.", "Sehr gerne.", "Okay, ich leg los.", "Erledige ich.",
        "Ist unterwegs.", "Dann los.",
    ],
    # -- a story or a statement --------------------------------------------------------------
    "erzaehlung": [
        "Mhm.", "Ah, verstehe.", "Ja, okay.", "Aha.", "Ich verstehe.", "Oh, interessant.",
        "Ah ja.", "Okay.", "Ja.", "Verstehe.", "Ah, okay.", "Hm, ja.", "Oh.",
        "Ach so.", "Ja, verstehe.", "Ah, spannend.", "Okay, verstehe.", "Mhm, ja.",
        "Ich verstehe, was du meinst.", "Ah, alles klar.",
        "Das klingt nach einer Menge.", "Ah, das wusste ich nicht.", "Mhm, erzähl ruhig weiter.",
        "Ja, das kann ich nachvollziehen.", "Okay, das hilft mir.", "Aha, so ist das also.",
        "Ja, das passt zusammen.", "Gut zu wissen.", "Ah, das ist neu für mich.", "Danke, das ist hilfreich.",
    ],
    "gefuehl": [
        "Oh, das klingt nicht schön.", "Hm, verstehe ich gut.", "Oh je.", "Ach, Mensch.",
        "Das kann ich verstehen.", "Oh, das tut mir leid.", "Hm, das ist echt nicht leicht.",
        "Puh, verstehe.", "Oh, okay.", "Mhm, das verstehe ich.",
        "Das klingt anstrengend.", "Ach, das ist wirklich blöd.", "Da bin ich ganz bei dir.",
        "Mensch, das tut mir leid zu hören.", "Das ist hart, ehrlich.",
    ],
    "freude": [
        "Oh, wie schön!", "Ah, super!", "Wow!", "Oh, toll!", "Cool!", "Klasse!",
        "Oh, das freut mich!", "Nice!", "Ha, super.", "Oh, sehr gut!",
        "Das ist ja großartig!", "Glückwunsch!", "Das hört sich richtig gut an.", "Mega, das freut mich.",
        "Wunderbar!",
    ],
    "meinung": [
        "Hm, wenn du mich fragst …", "Hm, lass mich kurz überlegen, was ich davon halte.",
        "Gute Frage, ich sag mal so.", "Hm, ehrlich gesagt.", "Also, ich finde, hm.",
        "Da hab ich eine Meinung.", "Hm, schwierig.", "Na ja, also.", "Hm, ich glaube.",
        "Also, wenn ich ehrlich bin.",
        "Ich würde sagen, hm.", "Das kommt drauf an, aber ich sag dir, was ich denke.",
        "Hm, da gibt es zwei Seiten.", "Ehrlich? Lass mich kurz abwägen.", "Okay, meine Einschätzung.",
    ],
    # -- the situation: what will be done -----------------------------------------------------
    "websuche": [
        "Moment, ich schau kurz im Netz nach.", "Ich schau mal nach.", "Sekunde, ich suche das raus.",
        "Okay, ich guck mal im Internet.", "Moment, ich check das kurz.", "Einen Augenblick, ich suche.",
        "Ich schau schnell nach.", "Warte, ich such das kurz.",
        "Das schau ich lieber nach, Moment.", "Ich suche kurz im Web danach.",
        "Okay, ich recherchiere das kurz.", "Da guck ich mal ins Netz.",
        "Moment, ich suche die aktuellen Infos.", "Ich google das schnell für dich.",
        "Dafür such ich kurz nach den neuesten Quellen.", "Das prüfe ich kurz online.",
        "Einen Moment, ich such dir das raus.", "Ich frag mal das Internet.",
        "Okay, ich sehe nach, was es dazu gibt.", "Mal sehen, was ich dazu finde.",
        "Da will ich auf Nummer sicher gehen und schau nach.", "Ich hole mir kurz frische Informationen.",
        "Das ist aktuell, da suche ich lieber nach.", "Gib mir einen Moment, ich recherchiere.",
        "Ich werf mal eine Suche an.", "Moment, ich durchsuche das Netz.",
        "Ich schaue nach, was die Quellen sagen.", "Sekunde, ich finde das raus.",
        "Dazu suche ich kurz nach verlässlichen Seiten.", "Ich vergleiche kurz ein paar Quellen.",
    ],
    "browser": [
        "Ich öffne das mal.", "Moment, ich mach die Seite auf.", "Okay, ich gehe auf die Seite.",
        "Ich schau mir die Seite mal an.", "Ich öffne einen neuen Tab dafür.", "Gleich, ich rufe das im Browser auf.",
        "Ich lade die Seite kurz.", "Moment, ich navigiere dorthin.", "Okay, ich klicke mich kurz durch.",
        "Ich seh mir das im Browser an.", "Einen Augenblick, die Seite lädt.", "Ich gehe kurz auf die Website.",
        "Dann öffne ich die Seite für dich.", "Ich lese mir die Seite kurz durch.",
        "Du kannst mir gleich zusehen, ich öffne das.", "Ich nehme mir einen eigenen Tab dafür.",
        "Okay, ich schau direkt auf der Seite nach.", "Moment, ich blättere kurz auf der Seite.",
        "Ich rufe die Seite auf und lese mit.", "Alles klar, ich ruf die Adresse auf.",
        "Ich geh mal rüber auf die Seite.", "Warte, ich öffne das im Browser.",
        "Ich füll das kurz aus, ein Moment.", "Ich öffne das und gebe dir gleich Bescheid.",
        "Ich steuere die Seite kurz an.",
    ],
    "brain": [
        "Ich schau in deine Notizen.", "Moment, ich suche in deinem Brain.", "Ich seh kurz in deinen Unterlagen nach.",
        "Ich guck mal, ob ich dazu was gespeichert habe.", "Einen Augenblick, ich durchsuche deine Notizen.",
        "Ich schlage das kurz in deinem Second Brain nach.", "Moment, das müsste ich irgendwo haben.",
        "Ich schau, was du dazu abgelegt hast.", "Ich blättere kurz in deinen Dokumenten.",
        "Sekunde, ich suche in deinen Dateien.", "Da war doch was in deinen Notizen, Moment.",
        "Ich prüfe kurz, was ich dazu von dir weiß.", "Ich such das in deinem Brain raus.",
        "Ich werf einen Blick in deine Sammlung.", "Ich sehe in deinen gespeicherten Seiten nach.",
        "Gleich, ich lese mir deinen Eintrag dazu durch.", "Moment, ich hole das aus deinem Archiv.",
        "Ich hab da was Gespeichertes, ich schau nach.", "Kurz in deine Notizen reinschauen, ja?",
        "Ich suche das in deinen eigenen Quellen.",
    ],
    "delegieren": [
        "Das gebe ich an einen meiner Assistenten.", "Dafür hole ich kurz jemanden dazu.",
        "Ich frag mal einen Kollegen.", "Das übernimmt einer meiner Assistenten.",
        "Moment, ich verteile das kurz.", "Ich beauftrage dafür einen Assistenten.",
        "Ich gebe das weiter, ein Moment.", "Da schalte ich einen Helfer ein.",
    ],
    "rechnen": [
        "Moment, ich rechne kurz.", "Ich rechne das schnell nach.", "Einen Augenblick, ich überschlage das.",
        "Ich tippe das kurz durch.", "Lass mich das kurz ausrechnen.", "Gleich, ich rechne nach.",
    ],
    "erklaeren": [
        "Okay, das erkläre ich dir gern.", "Gut, dann erkläre ich es Schritt für Schritt.",
        "Ich fass das mal zusammen.", "Alles klar, ich hole kurz aus.", "Das ist ein größeres Thema, ich versuch es kurz.",
        "Dann erzähl ich dir mal, wie das funktioniert.", "Okay, ich bring es auf den Punkt.",
        "Ich versuche, das einfach zu sagen.",
    ],
    "lob": [
        "Das ist eine richtig gute Idee.", "Spannender Punkt.", "Großartiger Gedanke.", "Das gefällt mir.",
        "Da hast du recht.", "Ja, das macht Sinn.", "Starker Vorschlag.", "Oh, daran hatte ich gar nicht gedacht, gut.",
        "Das ist clever.", "Guter Punkt, ehrlich.", "Das könnte wirklich funktionieren.",
        "Ich mag diese Idee.", "Stimmt, so kann man das sehen.", "Da steckt was drin.",
        "Das ist ein kluger Ansatz.",
    ],
    "ueberraschung": [
        "Oh, das hatte ich nicht bedacht.", "Hoppla, interessant.", "Oh, damit hätte ich nicht gerechnet.",
        "Echt jetzt?", "Ach, wirklich?", "Hm, das überrascht mich.", "Oh, das ist neu.", "Wow, okay.",
        "Das ist ja mal was.", "Ach, das ist spannend.", "Na sowas.", "Huch, okay.",
    ],
    "rueckfrage": [
        "Hm, meinst du das genau so?", "Moment, nur damit ich es richtig verstehe.", "Warte, lass mich kurz nachfragen.",
        "Okay, ich glaube, ich versteh das, aber lass mich kurz prüfen.", "Hm, da brauche ich noch einen Hinweis.",
        "Eine Sekunde, ich ordne das kurz.", "Ich bin mir nicht ganz sicher, was du meinst, ich überlege.",
        "Nur kurz zur Sicherheit, ich denke kurz nach.",
    ],
    "entschuldigung": [
        "Entschuldige, das war nicht gut.", "Sorry, da lag ich falsch.", "Oh, Verzeihung, ich korrigiere das.",
        "Tut mir leid, einen Moment, ich mache es besser.", "Ups, ich versuche es nochmal.",
        "Verzeih, ich war da zu schnell.", "Mein Fehler, ich schau nochmal.", "Das war missverständlich von mir, Moment.",
    ],
    "abschied": [
        "Bis später.", "Tschüss, bis bald.", "Machs gut.", "Bis zum nächsten Mal.", "Ich bin da, wenn du mich brauchst.",
        "Alles klar, ich bin still.", "Gerne, melde dich einfach.", "Bis gleich.", "Schönen Tag noch.",
        "Dann lass ich dich in Ruhe.",
    ],
    "hallo": [
        "Ja?", "Ja, ich bin da.", "Hi!", "Hallo!", "Hey!", "Ja, was gibt's?",
        "Hier bin ich.", "Ja, ich höre.", "Hey, was kann ich tun?", "Hallo, ja?",
        "Ich bin ganz Ohr.", "Ja, bitte?", "Na, was gibt's?", "Hey, schön dich zu hören.", "Da bin ich.",
    ],
    # -- it takes longer: said again after a few seconds of silence --------------------------------
    "warten": [
        "Das dauert einen Moment länger.", "Ich bin noch dran.", "Gleich habe ich es.", "Moment noch, ich bin fast da.",
        "Ich arbeite noch daran.", "Noch einen Augenblick, bitte.", "Die Seite braucht etwas.", "Das zieht sich gerade ein bisschen.",
        "Ich bin gleich fertig.", "Ein klein wenig Geduld noch.", "Es dauert nur noch kurz.", "Ich lese noch.",
    ],
    # -- you sent a vague or very short utterance ----------------------------------------------------
    "unklar": [
        "Hm, das habe ich nicht ganz verstanden.", "Magst du das nochmal sagen?", "Ich hab dich akustisch nicht ganz verstanden.",
        "Sag es bitte nochmal.", "Entschuldige, wie bitte?", "Das ist bei mir nicht richtig angekommen.",
    ],
    "danke": [
        "Gern geschehen.", "Immer gerne.", "Kein Ding.", "Sehr gern.", "Dafür bin ich da.", "Jederzeit.",
        "Freut mich, wenn ich helfen konnte.", "Gerne, das war schnell erledigt.",
    ],
}

# What the bridge says when the router only knows a rough route.
ROUTE_GROUP = {
    "web": "websuche",
    "browser": "browser",
    "brain": "brain",
    "delegate": "delegieren",
    "calc": "rechnen",
}
