"""Complete error sentences composed from reviewed verb/object forms.

Only source strings actually inventoried in the app are emitted. Object forms are
in the grammatical case required by each language, not translated in isolation.
"""
from pathlib import Path
import json


def add_errors(cat):
    # load/open/save/send/delete. Each cell is a complete sentence template.
    verbs = {
        'en': 'Could not load {x}.|Could not open {x}.|Could not save {x}.|Could not send {x}.|Could not delete {x}.',
        'de': 'Es war nicht möglich, {x} zu laden.|Es war nicht möglich, {x} zu öffnen.|Es war nicht möglich, {x} zu speichern.|Es war nicht möglich, {x} zu senden.|Es war nicht möglich, {x} zu löschen.',
        'es': 'No se pudo cargar {x}.|No se pudo abrir {x}.|No se pudo guardar {x}.|No se pudo enviar {x}.|No se pudo eliminar {x}.',
        'fr': 'Impossible de charger {x}.|Impossible d’ouvrir {x}.|Impossible d’enregistrer {x}.|Impossible d’envoyer {x}.|Impossible de supprimer {x}.',
        'it': 'Impossibile caricare {x}.|Impossibile aprire {x}.|Impossibile salvare {x}.|Impossibile inviare {x}.|Impossibile eliminare {x}.',
        'pt': 'Não foi possível carregar {x}.|Não foi possível abrir {x}.|Não foi possível guardar {x}.|Não foi possível enviar {x}.|Não foi possível eliminar {x}.',
        'el': 'Δεν ήταν δυνατή η φόρτωση {x}.|Δεν ήταν δυνατό το άνοιγμα {x}.|Δεν ήταν δυνατή η αποθήκευση {x}.|Δεν ήταν δυνατή η αποστολή {x}.|Δεν ήταν δυνατή η διαγραφή {x}.',
        'sr': 'Nije moguće učitati {x}.|Nije moguće otvoriti {x}.|Nije moguće sačuvati {x}.|Nije moguće poslati {x}.|Nije moguće izbrisati {x}.',
        'pl': 'Nie udało się wczytać {x}.|Nie udało się otworzyć {x}.|Nie udało się zapisać {x}.|Nie udało się wysłać {x}.|Nie udało się usunąć {x}.',
        'sl': 'Ni bilo mogoče naložiti {x}.|Ni bilo mogoče odpreti {x}.|Ni bilo mogoče shraniti {x}.|Ni bilo mogoče poslati {x}.|Ni bilo mogoče izbrisati {x}.',
        'sk': 'Nepodarilo sa načítať {x}.|Nepodarilo sa otvoriť {x}.|Nepodarilo sa uložiť {x}.|Nepodarilo sa odoslať {x}.|Nepodarilo sa odstrániť {x}.',
        'cs': 'Nepodařilo se načíst {x}.|Nepodařilo se otevřít {x}.|Nepodařilo se uložit {x}.|Nepodařilo se odeslat {x}.|Nepodařilo se odstranit {x}.',
        'bg': 'Неуспешно зареждане на {x}.|Неуспешно отваряне на {x}.|Неуспешно запазване на {x}.|Неуспешно изпращане на {x}.|Неуспешно изтриване на {x}.',
        'ro': 'Nu s-a putut încărca {x}.|Nu s-a putut deschide {x}.|Nu s-a putut salva {x}.|Nu s-a putut trimite {x}.|Nu s-a putut șterge {x}.',
        'mk': 'Неуспешно вчитување на {x}.|Неуспешно отворање на {x}.|Неуспешно зачувување на {x}.|Неуспешно испраќање на {x}.|Неуспешно бришење на {x}.',
        'hu': 'Nem sikerült betölteni {x}.|Nem sikerült megnyitni {x}.|Nem sikerült menteni {x}.|Nem sikerült elküldeni {x}.|Nem sikerült törölni {x}.',
        'sv': 'Det gick inte att läsa in {x}.|Det gick inte att öppna {x}.|Det gick inte att spara {x}.|Det gick inte att skicka {x}.|Det gick inte att ta bort {x}.',
        'nb': 'Kunne ikke laste {x}.|Kunne ikke åpne {x}.|Kunne ikke lagre {x}.|Kunne ikke sende {x}.|Kunne ikke slette {x}.',
        'fi': 'Ei voitu ladata {x}.|Ei voitu avata {x}.|Ei voitu tallentaa {x}.|Ei voitu lähettää {x}.|Ei voitu poistaa {x}.',
        'da': 'Kunne ikke indlæse {x}.|Kunne ikke åbne {x}.|Kunne ikke gemme {x}.|Kunne ikke sende {x}.|Kunne ikke slette {x}.',
        'nl': 'Kan {x} niet laden.|Kan {x} niet openen.|Kan {x} niet opslaan.|Kan {x} niet verzenden.|Kan {x} niet verwijderen.',
        'is': 'Ekki tókst að hlaða {x}.|Ekki tókst að opna {x}.|Ekki tókst að vista {x}.|Ekki tókst að senda {x}.|Ekki tókst að eyða {x}.',
    }
    ru_objects = 'профиль|фотографии|пользователей|публикации|публикацию|список|комментарии|встречи|встречу|сообщения|страну и регион|страны и регионы|документ|изображение|раздел|уведомление|анкету|все изменения|изменения|реакцию|результат|статус|письмо|сообщение|ответ|комментарий'.split('|')
    objects = {
        'en': 'the profile|the photos|the users|the posts|the post|the list|the comments|the meetings|the meeting|the messages|the country and region|the countries and regions|the document|the image|the section|the notification|the profile form|all changes|the changes|the reaction|the result|the status|the email|the message|the reply|the comment',
        'de': 'das Profil|die Fotos|die Nutzer|die Beiträge|den Beitrag|die Liste|die Kommentare|die Treffen|das Treffen|die Nachrichten|das Land und die Region|die Länder und Regionen|das Dokument|das Bild|den Bereich|die Benachrichtigung|das Profilformular|alle Änderungen|die Änderungen|die Reaktion|das Ergebnis|den Status|die E-Mail|die Nachricht|die Antwort|den Kommentar',
        'es': 'el perfil|las fotos|los usuarios|las publicaciones|la publicación|la lista|los comentarios|los encuentros|el encuentro|los mensajes|el país y la región|los países y las regiones|el documento|la imagen|la sección|la notificación|el formulario de perfil|todos los cambios|los cambios|la reacción|el resultado|el estado|el correo|el mensaje|la respuesta|el comentario',
        'fr': 'le profil|les photos|les utilisateurs|les publications|la publication|la liste|les commentaires|les rencontres|la rencontre|les messages|le pays et la région|les pays et les régions|le document|l’image|la rubrique|la notification|le formulaire de profil|toutes les modifications|les modifications|la réaction|le résultat|le statut|l’e-mail|le message|la réponse|le commentaire',
        'it': 'il profilo|le foto|gli utenti|i post|il post|l’elenco|i commenti|gli incontri|l’incontro|i messaggi|il paese e la regione|i paesi e le regioni|il documento|l’immagine|la sezione|la notifica|il modulo del profilo|tutte le modifiche|le modifiche|la reazione|il risultato|lo stato|l’email|il messaggio|la risposta|il commento',
        'pt': 'o perfil|as fotografias|os utilizadores|as publicações|a publicação|a lista|os comentários|os encontros|o encontro|as mensagens|o país e a região|os países e as regiões|o documento|a imagem|a secção|a notificação|o formulário do perfil|todas as alterações|as alterações|a reação|o resultado|o estado|o email|a mensagem|a resposta|o comentário',
        'el': 'του προφίλ|των φωτογραφιών|των χρηστών|των αναρτήσεων|της ανάρτησης|της λίστας|των σχολίων|των συναντήσεων|της συνάντησης|των μηνυμάτων|της χώρας και της περιοχής|των χωρών και των περιοχών|του εγγράφου|της εικόνας|της ενότητας|της ειδοποίησης|της φόρμας προφίλ|όλων των αλλαγών|των αλλαγών|της αντίδρασης|του αποτελέσματος|της κατάστασης|του email|του μηνύματος|της απάντησης|του σχολίου',
        'sr': 'profil|fotografije|korisnike|objave|objavu|listu|komentare|susrete|susret|poruke|državu i region|države i regione|dokument|sliku|odeljak|obaveštenje|obrazac profila|sve izmene|izmene|reakciju|rezultat|status|imejl|poruku|odgovor|komentar',
        'pl': 'profilu|zdjęć|użytkowników|postów|posta|listy|komentarzy|spotkań|spotkania|wiadomości|kraju i regionu|krajów i regionów|dokumentu|obrazu|sekcji|powiadomienia|formularza profilu|wszystkich zmian|zmian|reakcji|wyniku|statusu|e-maila|wiadomości|odpowiedzi|komentarza',
        'sl': 'profila|fotografij|uporabnikov|objav|objave|seznama|komentarjev|srečanj|srečanja|sporočil|države in regije|držav in regij|dokumenta|slike|razdelka|obvestila|obrazca profila|vseh sprememb|sprememb|odziva|rezultata|statusa|e-pošte|sporočila|odgovora|komentarja',
        'sk': 'profil|fotografie|používateľov|príspevky|príspevok|zoznam|komentáre|stretnutia|stretnutie|správy|krajinu a región|krajiny a regióny|dokument|obrázok|sekciu|oznámenie|profilový formulár|všetky zmeny|zmeny|reakciu|výsledok|stav|e-mail|správu|odpoveď|komentár',
        'cs': 'profil|fotografie|uživatele|příspěvky|příspěvek|seznam|komentáře|setkání|setkání|zprávy|zemi a region|země a regiony|dokument|obrázek|sekci|oznámení|profilový formulář|všechny změny|změny|reakci|výsledek|stav|e-mail|zprávu|odpověď|komentář',
        'bg': 'профила|снимките|потребителите|публикациите|публикацията|списъка|коментарите|срещите|срещата|съобщенията|държавата и региона|държавите и регионите|документа|изображението|раздела|известието|формуляра на профила|всички промени|промените|реакцията|резултата|статуса|имейла|съобщението|отговора|коментара',
        'ro': 'profilul|fotografiile|utilizatorii|postările|postarea|lista|comentariile|întâlnirile|întâlnirea|mesajele|țara și regiunea|țările și regiunile|documentul|imaginea|secțiunea|notificarea|formularul profilului|toate modificările|modificările|reacția|rezultatul|starea|e-mailul|mesajul|răspunsul|comentariul',
        'mk': 'профилот|фотографиите|корисниците|објавите|објавата|списокот|коментарите|средбите|средбата|пораките|земјата и регионот|земјите и регионите|документот|сликата|делот|известувањето|формуларот на профилот|сите промени|промените|реакцијата|резултатот|статусот|е-поштата|пораката|одговорот|коментарот',
        'hu': 'a profilt|a fényképeket|a felhasználókat|a bejegyzéseket|a bejegyzést|a listát|a hozzászólásokat|a találkozókat|a találkozót|az üzeneteket|az országot és a régiót|az országokat és a régiókat|a dokumentumot|a képet|a részt|az értesítést|a profilűrlapot|az összes módosítást|a módosításokat|a reakciót|az eredményt|az állapotot|az e-mailt|az üzenetet|a választ|a hozzászólást',
        'sv': 'profilen|fotona|användarna|inläggen|inlägget|listan|kommentarerna|träffarna|träffen|meddelandena|landet och regionen|länderna och regionerna|dokumentet|bilden|avsnittet|aviseringen|profilformuläret|alla ändringar|ändringarna|reaktionen|resultatet|statusen|e-postmeddelandet|meddelandet|svaret|kommentaren',
        'nb': 'profilen|bildene|brukerne|innleggene|innlegget|listen|kommentarene|treffene|treffet|meldingene|landet og regionen|landene og regionene|dokumentet|bildet|delen|varselet|profilskjemaet|alle endringer|endringene|reaksjonen|resultatet|statusen|e-posten|meldingen|svaret|kommentaren',
        'fi': 'profiilia|kuvia|käyttäjiä|julkaisuja|julkaisua|luetteloa|kommentteja|tapaamisia|tapaamista|viestejä|maata ja aluetta|maita ja alueita|asiakirjaa|kuvaa|osiota|ilmoitusta|profiililomaketta|kaikkia muutoksia|muutoksia|reaktiota|tulosta|tilaa|sähköpostia|viestiä|vastausta|kommenttia',
        'da': 'profilen|billederne|brugerne|opslagene|opslaget|listen|kommentarerne|møderne|mødet|beskederne|landet og regionen|landene og regionerne|dokumentet|billedet|afsnittet|notifikationen|profilformularen|alle ændringer|ændringerne|reaktionen|resultatet|statussen|e-mailen|beskeden|svaret|kommentaren',
        'nl': 'het profiel|de foto’s|de gebruikers|de berichten|het bericht|de lijst|de reacties|de ontmoetingen|de ontmoeting|de berichten|het land en de regio|de landen en regio’s|het document|de afbeelding|het onderdeel|de melding|het profielformulier|alle wijzigingen|de wijzigingen|de reactie|het resultaat|de status|de e-mail|het bericht|het antwoord|de reactie',
        'is': 'prófílnum|myndunum|notendunum|færslunum|færslunni|listanum|athugasemdunum|samkomunum|samkomunni|skilaboðunum|landinu og svæðinu|löndunum og svæðunum|skjalinu|myndinni|hlutanum|tilkynningunni|prófíleyðublaðinu|öllum breytingunum|breytingunum|viðbragðinu|niðurstöðunni|stöðunni|tölvupóstinum|skilaboðunum|svarinu|athugasemdinni',
    }
    is_acc = 'prófílinn|myndirnar|notendurna|færslurnar|færsluna|listann|athugasemdirnar|samkomurnar|samkomuna|skilaboðin|landið og svæðið|löndin og svæðin|skjalið|myndina|hlutann|tilkynninguna|prófíleyðublaðið|allar breytingarnar|breytingarnar|viðbragðið|niðurstöðuna|stöðuna|tölvupóstinn|skilaboðin|svarið|athugasemdina'.split('|')
    extra_objects = {'en':'the chat|the chats','de':'den Chat|die Chats','es':'el chat|los chats','fr':'la discussion|les discussions','it':'la chat|le chat','pt':'a conversa|as conversas','el':'της συνομιλίας|των συνομιλιών','sr':'razgovor|razgovore','pl':'czatu|czatów','sl':'klepeta|klepetov','sk':'čet|čety','cs':'chat|chaty','bg':'чата|чатовете','ro':'conversația|conversațiile','mk':'разговорот|разговорите','hu':'a beszélgetést|a beszélgetéseket','sv':'chatten|chattarna','nb':'chatten|chattene','fi':'keskustelua|keskusteluja','da':'chatten|chattene','nl':'de chat|de chats','is':'spjallinu|spjöllunum'}
    ru_objects.extend(['чат', 'чаты'])
    for code, values in extra_objects.items():
        objects[code] += '|' + values
    is_acc.extend(['spjallið', 'spjöllin'])
    ru_suffix = ['', ' Проверьте подключение.', ' Проверьте соединение.', ' Попробуйте ещё раз.', ' Повторите попытку.', ' Проверьте соединение и повторите попытку.', ' Проверьте подключение и повторите попытку.', ' Проверьте сеанс и повторите попытку.']
    suffix = {
        'en': '| Check your connection.| Check your connection.| Please try again.| Please try again.| Check your connection and try again.| Check your connection and try again.| Check your session and try again.',
        'de': '| Prüfen Sie Ihre Verbindung.| Prüfen Sie Ihre Verbindung.| Versuchen Sie es erneut.| Versuchen Sie es erneut.| Prüfen Sie Ihre Verbindung und versuchen Sie es erneut.| Prüfen Sie Ihre Verbindung und versuchen Sie es erneut.| Prüfen Sie Ihre Sitzung und versuchen Sie es erneut.',
        'es': '| Comprueba la conexión.| Comprueba la conexión.| Inténtalo de nuevo.| Inténtalo de nuevo.| Comprueba la conexión e inténtalo de nuevo.| Comprueba la conexión e inténtalo de nuevo.| Comprueba tu sesión e inténtalo de nuevo.',
        'fr': '| Vérifiez votre connexion.| Vérifiez votre connexion.| Réessayez.| Réessayez.| Vérifiez votre connexion et réessayez.| Vérifiez votre connexion et réessayez.| Vérifiez votre session et réessayez.',
        'it': '| Controlla la connessione.| Controlla la connessione.| Riprova.| Riprova.| Controlla la connessione e riprova.| Controlla la connessione e riprova.| Controlla la sessione e riprova.',
        'pt': '| Verifique a ligação.| Verifique a ligação.| Tente novamente.| Tente novamente.| Verifique a ligação e tente novamente.| Verifique a ligação e tente novamente.| Verifique a sessão e tente novamente.',
        'el': '| Ελέγξτε τη σύνδεσή σας.| Ελέγξτε τη σύνδεσή σας.| Δοκιμάστε ξανά.| Δοκιμάστε ξανά.| Ελέγξτε τη σύνδεσή σας και δοκιμάστε ξανά.| Ελέγξτε τη σύνδεσή σας και δοκιμάστε ξανά.| Ελέγξτε τη συνεδρία σας και δοκιμάστε ξανά.',
        'sr': '| Proverite vezu.| Proverite vezu.| Pokušajte ponovo.| Pokušajte ponovo.| Proverite vezu i pokušajte ponovo.| Proverite vezu i pokušajte ponovo.| Proverite sesiju i pokušajte ponovo.',
        'pl': '| Sprawdź połączenie.| Sprawdź połączenie.| Spróbuj ponownie.| Spróbuj ponownie.| Sprawdź połączenie i spróbuj ponownie.| Sprawdź połączenie i spróbuj ponownie.| Sprawdź sesję i spróbuj ponownie.',
        'sl': '| Preverite povezavo.| Preverite povezavo.| Poskusite znova.| Poskusite znova.| Preverite povezavo in poskusite znova.| Preverite povezavo in poskusite znova.| Preverite sejo in poskusite znova.',
        'sk': '| Skontrolujte pripojenie.| Skontrolujte pripojenie.| Skúste to znova.| Skúste to znova.| Skontrolujte pripojenie a skúste to znova.| Skontrolujte pripojenie a skúste to znova.| Skontrolujte reláciu a skúste to znova.',
        'cs': '| Zkontrolujte připojení.| Zkontrolujte připojení.| Zkuste to znovu.| Zkuste to znovu.| Zkontrolujte připojení a zkuste to znovu.| Zkontrolujte připojení a zkuste to znovu.| Zkontrolujte relaci a zkuste to znovu.',
        'bg': '| Проверете връзката.| Проверете връзката.| Опитайте отново.| Опитайте отново.| Проверете връзката и опитайте отново.| Проверете връзката и опитайте отново.| Проверете сесията и опитайте отново.',
        'ro': '| Verifică conexiunea.| Verifică conexiunea.| Încearcă din nou.| Încearcă din nou.| Verifică conexiunea și încearcă din nou.| Verifică conexiunea și încearcă din nou.| Verifică sesiunea și încearcă din nou.',
        'mk': '| Проверете ја врската.| Проверете ја врската.| Обидете се повторно.| Обидете се повторно.| Проверете ја врската и обидете се повторно.| Проверете ја врската и обидете се повторно.| Проверете ја сесијата и обидете се повторно.',
        'hu': '| Ellenőrizze a kapcsolatot.| Ellenőrizze a kapcsolatot.| Próbálja újra.| Próbálja újra.| Ellenőrizze a kapcsolatot, majd próbálja újra.| Ellenőrizze a kapcsolatot, majd próbálja újra.| Ellenőrizze a munkamenetet, majd próbálja újra.',
        'sv': '| Kontrollera anslutningen.| Kontrollera anslutningen.| Försök igen.| Försök igen.| Kontrollera anslutningen och försök igen.| Kontrollera anslutningen och försök igen.| Kontrollera sessionen och försök igen.',
        'nb': '| Sjekk tilkoblingen.| Sjekk tilkoblingen.| Prøv igjen.| Prøv igjen.| Sjekk tilkoblingen og prøv igjen.| Sjekk tilkoblingen og prøv igjen.| Sjekk økten og prøv igjen.',
        'fi': '| Tarkista yhteys.| Tarkista yhteys.| Yritä uudelleen.| Yritä uudelleen.| Tarkista yhteys ja yritä uudelleen.| Tarkista yhteys ja yritä uudelleen.| Tarkista istunto ja yritä uudelleen.',
        'da': '| Tjek forbindelsen.| Tjek forbindelsen.| Prøv igen.| Prøv igen.| Tjek forbindelsen, og prøv igen.| Tjek forbindelsen, og prøv igen.| Tjek sessionen, og prøv igen.',
        'nl': '| Controleer de verbinding.| Controleer de verbinding.| Probeer het opnieuw.| Probeer het opnieuw.| Controleer de verbinding en probeer het opnieuw.| Controleer de verbinding en probeer het opnieuw.| Controleer de sessie en probeer het opnieuw.',
        'is': '| Athugaðu tenginguna.| Athugaðu tenginguna.| Reyndu aftur.| Reyndu aftur.| Athugaðu tenginguna og reyndu aftur.| Athugaðu tenginguna og reyndu aftur.| Athugaðu setuna og reyndu aftur.',
    }
    sources = set()
    root = Path(__file__).resolve().parents[1]
    # Keep the reviewed source list with the generator. A local, disposable
    # UI inventory must not be required to reproduce published translations.
    sources.update(json.loads((root / 'tool/l10n_error_sources.json').read_text()))
    sources.update('''Не удалось загрузить фотографии.|Не удалось загрузить профиль.|Не удалось загрузить публикации.|Не удалось загрузить публикацию.|Не удалось загрузить список.|Не удалось открыть профиль. Попробуйте ещё раз.|Не удалось отправить комментарий. Попробуйте ещё раз.|Не удалось открыть уведомление. Проверьте подключение.'''.split('|'))
    sources.add('Не удалось загрузить страну и регион.')
    ru_verbs = ['загрузить','открыть','сохранить','отправить','удалить']
    for code in verbs:
        assert len(objects[code].split('|')) == len(ru_objects), code
        assert len(suffix[code].split('|')) == len(ru_suffix), code
    curated = set()
    for segment in (root / 'tool/l10n_segments').glob('*.json'):
        if not segment.name.endswith('.draft.json'):
            curated.update(json.loads(segment.read_text())['ru'])
    for key in sorted(sources - curated):
        for vi, verb in enumerate(ru_verbs):
            for oi, obj in enumerate(ru_objects):
                stem = f'Не удалось {verb} {obj}'
                if not key.startswith(stem):
                    continue
                tail = key[len(stem):]
                if tail == '':
                    si = 0
                elif tail.startswith('.') and tail[1:] in ru_suffix:
                    si = ru_suffix.index(tail[1:])
                else:
                    continue
                for code in cat:
                    if code == 'ru':
                        cat[code][key] = key
                    else:
                        noun = objects[code].split('|')[oi]
                        if code == 'is' and vi in (1,2,3):
                            noun = is_acc[oi]
                        cat[code][key] = verbs[code].split('|')[vi].format(x=noun) + suffix[code].split('|')[si]
