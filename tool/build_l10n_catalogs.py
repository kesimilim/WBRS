#!/usr/bin/env python3
"""Deterministically assemble explicit source translations; never auto-fill English.
Each row explicitly provides all 23 languages. Missing cells fail the build.
"""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CODES = 'en de es fr it pt el ru sr pl sl sk cs bg ro mk hu sv nb fi da nl is'.split()
CAT = {code: {} for code in CODES}
def batch(keys, values):
    keys = keys.strip().split('|')
    assert set(values) == set(CODES) - {'ru'}, set(values)
    for code in CODES:
        translations = keys if code == 'ru' else values[code].strip().split('|')
        assert len(translations) == len(keys), (code,len(translations),len(keys))
        for key, value in zip(keys, translations):
            assert value.strip(), (code,key)
            CAT[code][key] = value

batch('''Язык|Закрыть|Отмена|Сохранить|Повторить|Повторить попытку|Да|Нет|Войти|Вход|Регистрация|Зарегистрироваться|Выйти|Пароль|Повторите пароль|Имя|Возраст|Пол|Страна|Регион|О себе|Интересы и увлечения|Рост|Есть дети?|Мужской|Женский|Мужчины|Женщины|Все|Любой|Любая|Все страны|Все регионы|Встречи|Создать встречу|Изменить встречу|Название встречи|Описание встречи|Тип встречи|Индивидуальная встреча|Коллективная встреча|Участники|Участники встречи|Присоединиться|Выйти из встречи|Лента|Люди|Чаты|Профиль|Друзья|Уведомления|О приложении|Обратная связь|Правила использования|Политика конфиденциальности|Пользовательское соглашение|Публичная оферта|Комментарии|Комментарий|Ответить|Ответы|Отправить сообщение|Отправить комментарий|Копировать|Удалить|Редактировать|Обновить|Добавить|Выбрать|Фотографии|Добавить фото|Фото профиля|Поиск по никнейму|Применить|Сбросить|Понятно|Пройти тест|Запомнить меня|Забыли пароль?|Сбросить пароль|Проверить результат|Проверить отправку|Предыдущая страница|Следующая страница|Пользователь|Настройки''', {
'en': '''Language|Close|Cancel|Save|Retry|Try again|Yes|No|Sign in|Sign in|Registration|Register|Sign out|Password|Repeat password|Name|Age|Gender|Country|Region|About me|Interests and hobbies|Height|Do you have children?|Male|Female|Men|Women|All|Any|Any|All countries|All regions|Meetings|Create meeting|Edit meeting|Meeting title|Meeting description|Meeting type|One-to-one meeting|Group meeting|Participants|Meeting participants|Join|Leave meeting|Feed|People|Chats|Profile|Friends|Notifications|About the app|Feedback|Community rules|Privacy policy|User agreement|Public offer|Comments|Comment|Reply|Replies|Send message|Send comment|Copy|Delete|Edit|Refresh|Add|Select|Photos|Add photo|Profile photo|Search by nickname|Apply|Reset|Got it|Take the test|Remember me|Forgot password?|Reset password|Check result|Check sending status|Previous page|Next page|User|Settings''',
'de': '''Sprache|Schließen|Abbrechen|Speichern|Erneut versuchen|Noch einmal versuchen|Ja|Nein|Anmelden|Anmeldung|Registrierung|Registrieren|Abmelden|Passwort|Passwort wiederholen|Name|Alter|Geschlecht|Land|Region|Über mich|Interessen und Hobbys|Größe|Haben Sie Kinder?|Männlich|Weiblich|Männer|Frauen|Alle|Beliebig|Beliebig|Alle Länder|Alle Regionen|Treffen|Treffen erstellen|Treffen bearbeiten|Titel des Treffens|Beschreibung des Treffens|Art des Treffens|Treffen zu zweit|Gruppentreffen|Teilnehmer|Teilnehmer des Treffens|Teilnehmen|Treffen verlassen|Beiträge|Personen|Chats|Profil|Freunde|Benachrichtigungen|Über die App|Feedback|Nutzungsregeln|Datenschutzerklärung|Nutzungsvereinbarung|Öffentliches Vertragsangebot|Kommentare|Kommentar|Antworten|Antworten|Nachricht senden|Kommentar senden|Kopieren|Löschen|Bearbeiten|Aktualisieren|Hinzufügen|Auswählen|Fotos|Foto hinzufügen|Profilfoto|Nach Spitznamen suchen|Anwenden|Zurücksetzen|Verstanden|Test machen|Angemeldet bleiben|Passwort vergessen?|Passwort zurücksetzen|Ergebnis prüfen|Sendestatus prüfen|Vorherige Seite|Nächste Seite|Benutzer|Einstellungen''',
'es': '''Idioma|Cerrar|Cancelar|Guardar|Reintentar|Intentar de nuevo|Sí|No|Iniciar sesión|Inicio de sesión|Registro|Registrarse|Cerrar sesión|Contraseña|Repite la contraseña|Nombre|Edad|Género|País|Región|Sobre mí|Intereses y aficiones|Estatura|¿Tienes hijos?|Masculino|Femenino|Hombres|Mujeres|Todos|Cualquiera|Cualquiera|Todos los países|Todas las regiones|Encuentros|Crear encuentro|Editar encuentro|Nombre del encuentro|Descripción del encuentro|Tipo de encuentro|Encuentro individual|Encuentro grupal|Participantes|Participantes del encuentro|Unirse|Salir del encuentro|Publicaciones|Personas|Chats|Perfil|Amigos|Notificaciones|Acerca de la aplicación|Comentarios y sugerencias|Normas de uso|Política de privacidad|Acuerdo de usuario|Oferta pública|Comentarios|Comentario|Responder|Respuestas|Enviar mensaje|Enviar comentario|Copiar|Eliminar|Editar|Actualizar|Añadir|Seleccionar|Fotos|Añadir foto|Foto de perfil|Buscar por apodo|Aplicar|Restablecer|Entendido|Hacer el test|Recordarme|¿Olvidaste tu contraseña?|Restablecer contraseña|Comprobar resultado|Comprobar envío|Página anterior|Página siguiente|Usuario|Ajustes''',
'fr': '''Langue|Fermer|Annuler|Enregistrer|Réessayer|Essayer à nouveau|Oui|Non|Se connecter|Connexion|Inscription|S’inscrire|Se déconnecter|Mot de passe|Confirmer le mot de passe|Prénom|Âge|Genre|Pays|Région|À propos de moi|Centres d’intérêt et loisirs|Taille|Avez-vous des enfants ?|Masculin|Féminin|Hommes|Femmes|Tous|Tous|Toutes|Tous les pays|Toutes les régions|Rencontres|Créer une rencontre|Modifier la rencontre|Titre de la rencontre|Description de la rencontre|Type de rencontre|Rencontre à deux|Rencontre de groupe|Participants|Participants à la rencontre|Rejoindre|Quitter la rencontre|Fil|Personnes|Discussions|Profil|Amis|Notifications|À propos de l’application|Nous contacter|Règles d’utilisation|Politique de confidentialité|Conditions d’utilisation|Offre publique|Commentaires|Commentaire|Répondre|Réponses|Envoyer le message|Envoyer le commentaire|Copier|Supprimer|Modifier|Actualiser|Ajouter|Sélectionner|Photos|Ajouter une photo|Photo de profil|Rechercher par pseudonyme|Appliquer|Réinitialiser|Compris|Passer le test|Se souvenir de moi|Mot de passe oublié ?|Réinitialiser le mot de passe|Vérifier le résultat|Vérifier l’envoi|Page précédente|Page suivante|Utilisateur|Paramètres''',
'it': '''Lingua|Chiudi|Annulla|Salva|Riprova|Prova di nuovo|Sì|No|Accedi|Accesso|Registrazione|Registrati|Esci|Password|Ripeti la password|Nome|Età|Genere|Paese|Regione|Su di me|Interessi e hobby|Altezza|Hai figli?|Maschile|Femminile|Uomini|Donne|Tutti|Qualsiasi|Qualsiasi|Tutti i paesi|Tutte le regioni|Incontri|Crea incontro|Modifica incontro|Titolo dell’incontro|Descrizione dell’incontro|Tipo di incontro|Incontro individuale|Incontro di gruppo|Partecipanti|Partecipanti all’incontro|Partecipa|Abbandona l’incontro|Bacheca|Persone|Chat|Profilo|Amici|Notifiche|Informazioni sull’app|Contattaci|Regole d’uso|Informativa sulla privacy|Accordo con l’utente|Offerta pubblica|Commenti|Commento|Rispondi|Risposte|Invia messaggio|Invia commento|Copia|Elimina|Modifica|Aggiorna|Aggiungi|Seleziona|Foto|Aggiungi foto|Foto del profilo|Cerca per soprannome|Applica|Reimposta|Ho capito|Fai il test|Ricordami|Password dimenticata?|Reimposta password|Verifica risultato|Verifica invio|Pagina precedente|Pagina successiva|Utente|Impostazioni''',
'pt': '''Idioma|Fechar|Cancelar|Guardar|Tentar novamente|Tentar de novo|Sim|Não|Entrar|Início de sessão|Registo|Registar|Sair|Palavra-passe|Repita a palavra-passe|Nome|Idade|Género|País|Região|Sobre mim|Interesses e passatempos|Altura|Tem filhos?|Masculino|Feminino|Homens|Mulheres|Todos|Qualquer|Qualquer|Todos os países|Todas as regiões|Encontros|Criar encontro|Editar encontro|Título do encontro|Descrição do encontro|Tipo de encontro|Encontro individual|Encontro em grupo|Participantes|Participantes do encontro|Participar|Sair do encontro|Publicações|Pessoas|Conversas|Perfil|Amigos|Notificações|Sobre a aplicação|Contacto|Regras de utilização|Política de privacidade|Acordo do utilizador|Oferta pública|Comentários|Comentário|Responder|Respostas|Enviar mensagem|Enviar comentário|Copiar|Eliminar|Editar|Atualizar|Adicionar|Selecionar|Fotografias|Adicionar fotografia|Fotografia de perfil|Pesquisar por alcunha|Aplicar|Repor|Entendido|Fazer o teste|Lembrar-me|Esqueceu-se da palavra-passe?|Repor palavra-passe|Verificar resultado|Verificar envio|Página anterior|Página seguinte|Utilizador|Definições''',
'el': '''Γλώσσα|Κλείσιμο|Ακύρωση|Αποθήκευση|Επανάληψη|Δοκιμάστε ξανά|Ναι|Όχι|Σύνδεση|Σύνδεση|Εγγραφή|Εγγραφείτε|Αποσύνδεση|Κωδικός πρόσβασης|Επαναλάβετε τον κωδικό|Όνομα|Ηλικία|Φύλο|Χώρα|Περιοχή|Σχετικά με εμένα|Ενδιαφέροντα και χόμπι|Ύψος|Έχετε παιδιά;|Άνδρας|Γυναίκα|Άνδρες|Γυναίκες|Όλα|Οποιοδήποτε|Οποιαδήποτε|Όλες οι χώρες|Όλες οι περιοχές|Συναντήσεις|Δημιουργία συνάντησης|Επεξεργασία συνάντησης|Τίτλος συνάντησης|Περιγραφή συνάντησης|Τύπος συνάντησης|Ατομική συνάντηση|Ομαδική συνάντηση|Συμμετέχοντες|Συμμετέχοντες στη συνάντηση|Συμμετοχή|Αποχώρηση από τη συνάντηση|Ροή|Άτομα|Συνομιλίες|Προφίλ|Φίλοι|Ειδοποιήσεις|Σχετικά με την εφαρμογή|Επικοινωνία|Κανόνες χρήσης|Πολιτική απορρήτου|Συμφωνία χρήστη|Δημόσια προσφορά|Σχόλια|Σχόλιο|Απάντηση|Απαντήσεις|Αποστολή μηνύματος|Αποστολή σχολίου|Αντιγραφή|Διαγραφή|Επεξεργασία|Ανανέωση|Προσθήκη|Επιλογή|Φωτογραφίες|Προσθήκη φωτογραφίας|Φωτογραφία προφίλ|Αναζήτηση με ψευδώνυμο|Εφαρμογή|Επαναφορά|Κατάλαβα|Κάντε το τεστ|Να με θυμάσαι|Ξεχάσατε τον κωδικό;|Επαναφορά κωδικού|Έλεγχος αποτελέσματος|Έλεγχος αποστολής|Προηγούμενη σελίδα|Επόμενη σελίδα|Χρήστης|Ρυθμίσεις''',
'sr': '''Jezik|Zatvori|Otkaži|Sačuvaj|Pokušaj ponovo|Pokušaj ponovo|Da|Ne|Prijavi se|Prijava|Registracija|Registruj se|Odjavi se|Lozinka|Ponovite lozinku|Ime|Godine|Pol|Država|Region|O meni|Interesovanja i hobiji|Visina|Imate li decu?|Muški|Ženski|Muškarci|Žene|Sve|Bilo koji|Bilo koja|Sve države|Svi regioni|Susreti|Kreiraj susret|Izmeni susret|Naziv susreta|Opis susreta|Vrsta susreta|Susret udvoje|Grupni susret|Učesnici|Učesnici susreta|Pridruži se|Napusti susret|Objave|Ljudi|Razgovori|Profil|Prijatelji|Obaveštenja|O aplikaciji|Kontakt|Pravila korišćenja|Politika privatnosti|Korisnički ugovor|Javna ponuda|Komentari|Komentar|Odgovori|Odgovori|Pošalji poruku|Pošalji komentar|Kopiraj|Obriši|Izmeni|Osveži|Dodaj|Izaberi|Fotografije|Dodaj fotografiju|Profilna fotografija|Pretraga po nadimku|Primeni|Poništi|Razumem|Uradi test|Zapamti me|Zaboravili ste lozinku?|Resetuj lozinku|Proveri rezultat|Proveri slanje|Prethodna stranica|Sledeća stranica|Korisnik|Podešavanja''',
'pl': '''Język|Zamknij|Anuluj|Zapisz|Ponów|Spróbuj ponownie|Tak|Nie|Zaloguj się|Logowanie|Rejestracja|Zarejestruj się|Wyloguj się|Hasło|Powtórz hasło|Imię|Wiek|Płeć|Kraj|Region|O mnie|Zainteresowania i hobby|Wzrost|Masz dzieci?|Męska|Żeńska|Mężczyźni|Kobiety|Wszystkie|Dowolny|Dowolna|Wszystkie kraje|Wszystkie regiony|Spotkania|Utwórz spotkanie|Edytuj spotkanie|Nazwa spotkania|Opis spotkania|Rodzaj spotkania|Spotkanie we dwoje|Spotkanie grupowe|Uczestnicy|Uczestnicy spotkania|Dołącz|Opuść spotkanie|Aktualności|Osoby|Czaty|Profil|Znajomi|Powiadomienia|O aplikacji|Kontakt|Zasady korzystania|Polityka prywatności|Umowa użytkownika|Oferta publiczna|Komentarze|Komentarz|Odpowiedz|Odpowiedzi|Wyślij wiadomość|Wyślij komentarz|Kopiuj|Usuń|Edytuj|Odśwież|Dodaj|Wybierz|Zdjęcia|Dodaj zdjęcie|Zdjęcie profilowe|Szukaj według pseudonimu|Zastosuj|Resetuj|Rozumiem|Wykonaj test|Zapamiętaj mnie|Nie pamiętasz hasła?|Zresetuj hasło|Sprawdź wynik|Sprawdź wysyłanie|Poprzednia strona|Następna strona|Użytkownik|Ustawienia''',
'sl': '''Jezik|Zapri|Prekliči|Shrani|Poskusi znova|Poskusi ponovno|Da|Ne|Prijavi se|Prijava|Registracija|Registriraj se|Odjavi se|Geslo|Ponovite geslo|Ime|Starost|Spol|Država|Regija|O meni|Zanimanja in hobiji|Višina|Imate otroke?|Moški|Ženski|Moški|Ženske|Vse|Katerikoli|Katerakoli|Vse države|Vse regije|Srečanja|Ustvari srečanje|Uredi srečanje|Naslov srečanja|Opis srečanja|Vrsta srečanja|Srečanje v dvoje|Skupinsko srečanje|Udeleženci|Udeleženci srečanja|Pridruži se|Zapusti srečanje|Objave|Ljudje|Klepeti|Profil|Prijatelji|Obvestila|O aplikaciji|Povratne informacije|Pravila uporabe|Pravilnik o zasebnosti|Uporabniška pogodba|Javna ponudba|Komentarji|Komentar|Odgovori|Odgovori|Pošlji sporočilo|Pošlji komentar|Kopiraj|Izbriši|Uredi|Osveži|Dodaj|Izberi|Fotografije|Dodaj fotografijo|Profilna fotografija|Iskanje po vzdevku|Uporabi|Ponastavi|Razumem|Opravi test|Zapomni si me|Ste pozabili geslo?|Ponastavi geslo|Preveri rezultat|Preveri pošiljanje|Prejšnja stran|Naslednja stran|Uporabnik|Nastavitve''',
'sk': '''Jazyk|Zavrieť|Zrušiť|Uložiť|Skúsiť znova|Skúsiť opäť|Áno|Nie|Prihlásiť sa|Prihlásenie|Registrácia|Zaregistrovať sa|Odhlásiť sa|Heslo|Zopakujte heslo|Meno|Vek|Pohlavie|Krajina|Región|O mne|Záujmy a záľuby|Výška|Máte deti?|Mužské|Ženské|Muži|Ženy|Všetky|Ľubovoľný|Ľubovoľná|Všetky krajiny|Všetky regióny|Stretnutia|Vytvoriť stretnutie|Upraviť stretnutie|Názov stretnutia|Opis stretnutia|Typ stretnutia|Stretnutie vo dvojici|Skupinové stretnutie|Účastníci|Účastníci stretnutia|Pripojiť sa|Opustiť stretnutie|Príspevky|Ľudia|Čety|Profil|Priatelia|Oznámenia|O aplikácii|Spätná väzba|Pravidlá používania|Zásady ochrany súkromia|Používateľská zmluva|Verejná ponuka|Komentáre|Komentár|Odpovedať|Odpovede|Odoslať správu|Odoslať komentár|Kopírovať|Odstrániť|Upraviť|Obnoviť|Pridať|Vybrať|Fotografie|Pridať fotografiu|Profilová fotografia|Hľadať podľa prezývky|Použiť|Obnoviť nastavenia|Rozumiem|Absolvovať test|Zapamätať si ma|Zabudli ste heslo?|Obnoviť heslo|Overiť výsledok|Overiť odoslanie|Predchádzajúca strana|Nasledujúca strana|Používateľ|Nastavenia''',
'cs': '''Jazyk|Zavřít|Zrušit|Uložit|Zkusit znovu|Zkusit znovu|Ano|Ne|Přihlásit se|Přihlášení|Registrace|Zaregistrovat se|Odhlásit se|Heslo|Zopakujte heslo|Jméno|Věk|Pohlaví|Země|Region|O mně|Zájmy a koníčky|Výška|Máte děti?|Mužské|Ženské|Muži|Ženy|Všechny|Libovolný|Libovolná|Všechny země|Všechny regiony|Setkání|Vytvořit setkání|Upravit setkání|Název setkání|Popis setkání|Typ setkání|Setkání ve dvou|Skupinové setkání|Účastníci|Účastníci setkání|Připojit se|Opustit setkání|Příspěvky|Lidé|Chaty|Profil|Přátelé|Oznámení|O aplikaci|Zpětná vazba|Pravidla používání|Zásady ochrany soukromí|Uživatelská smlouva|Veřejná nabídka|Komentáře|Komentář|Odpovědět|Odpovědi|Odeslat zprávu|Odeslat komentář|Kopírovat|Odstranit|Upravit|Obnovit|Přidat|Vybrat|Fotografie|Přidat fotografii|Profilová fotografie|Hledat podle přezdívky|Použít|Obnovit nastavení|Rozumím|Vyplnit test|Zapamatovat si mě|Zapomněli jste heslo?|Obnovit heslo|Ověřit výsledek|Ověřit odeslání|Předchozí stránka|Další stránka|Uživatel|Nastavení''',
'bg': '''Език|Затвори|Отказ|Запази|Опитай отново|Опитай пак|Да|Не|Вход|Вход|Регистрация|Регистрирай се|Изход|Парола|Повторете паролата|Име|Възраст|Пол|Държава|Регион|За мен|Интереси и хобита|Ръст|Имате ли деца?|Мъжки|Женски|Мъже|Жени|Всички|Всеки|Всяка|Всички държави|Всички региони|Срещи|Създай среща|Редактирай среща|Име на срещата|Описание на срещата|Вид среща|Индивидуална среща|Групова среща|Участници|Участници в срещата|Присъедини се|Напусни срещата|Публикации|Хора|Чатове|Профил|Приятели|Известия|За приложението|Обратна връзка|Правила за използване|Политика за поверителност|Потребителско споразумение|Публична оферта|Коментари|Коментар|Отговори|Отговори|Изпрати съобщение|Изпрати коментар|Копирай|Изтрий|Редактирай|Обнови|Добави|Избери|Снимки|Добави снимка|Профилна снимка|Търсене по псевдоним|Приложи|Нулирай|Разбрах|Направи теста|Запомни ме|Забравена парола?|Нулирай паролата|Провери резултата|Провери изпращането|Предишна страница|Следваща страница|Потребител|Настройки''',
'ro': '''Limbă|Închide|Anulează|Salvează|Reîncearcă|Încearcă din nou|Da|Nu|Autentificare|Autentificare|Înregistrare|Înregistrează-te|Deconectare|Parolă|Repetă parola|Nume|Vârstă|Gen|Țară|Regiune|Despre mine|Interese și hobbyuri|Înălțime|Ai copii?|Masculin|Feminin|Bărbați|Femei|Toate|Oricare|Oricare|Toate țările|Toate regiunile|Întâlniri|Creează întâlnire|Editează întâlnirea|Titlul întâlnirii|Descrierea întâlnirii|Tipul întâlnirii|Întâlnire în doi|Întâlnire de grup|Participanți|Participanții întâlnirii|Alătură-te|Părăsește întâlnirea|Publicații|Persoane|Conversații|Profil|Prieteni|Notificări|Despre aplicație|Feedback|Reguli de utilizare|Politica de confidențialitate|Acordul utilizatorului|Ofertă publică|Comentarii|Comentariu|Răspunde|Răspunsuri|Trimite mesaj|Trimite comentariu|Copiază|Șterge|Editează|Actualizează|Adaugă|Selectează|Fotografii|Adaugă fotografie|Fotografie de profil|Caută după pseudonim|Aplică|Resetează|Am înțeles|Fă testul|Ține-mă minte|Ai uitat parola?|Resetează parola|Verifică rezultatul|Verifică trimiterea|Pagina anterioară|Pagina următoare|Utilizator|Setări''',
'mk': '''Јазик|Затвори|Откажи|Зачувај|Обиди се повторно|Обиди се пак|Да|Не|Најави се|Најава|Регистрација|Регистрирај се|Одјави се|Лозинка|Повторете ја лозинката|Име|Возраст|Пол|Држава|Регион|За мене|Интереси и хобија|Висина|Имате ли деца?|Машки|Женски|Мажи|Жени|Сите|Кој било|Која било|Сите држави|Сите региони|Средби|Создај средба|Уреди средба|Наслов на средбата|Опис на средбата|Вид на средба|Средба во пар|Групна средба|Учесници|Учесници на средбата|Приклучи се|Напушти ја средбата|Објави|Луѓе|Разговори|Профил|Пријатели|Известувања|За апликацијата|Повратни информации|Правила за користење|Политика за приватност|Кориснички договор|Јавна понуда|Коментари|Коментар|Одговори|Одговори|Испрати порака|Испрати коментар|Копирај|Избриши|Уреди|Освежи|Додај|Избери|Фотографии|Додај фотографија|Профилна фотографија|Пребарај по прекар|Примени|Ресетирај|Разбирам|Направи го тестот|Запомни ме|Ја заборавивте лозинката?|Ресетирај лозинка|Провери резултат|Провери испраќање|Претходна страница|Следна страница|Корисник|Поставки''',
'hu': '''Nyelv|Bezárás|Mégse|Mentés|Újra|Újrapróbálkozás|Igen|Nem|Bejelentkezés|Bejelentkezés|Regisztráció|Regisztráció|Kijelentkezés|Jelszó|Jelszó ismét|Név|Életkor|Nem|Ország|Régió|Magamról|Érdeklődési kör és hobbik|Magasság|Van gyermeke?|Férfi|Nő|Férfiak|Nők|Összes|Bármelyik|Bármelyik|Minden ország|Minden régió|Találkozók|Találkozó létrehozása|Találkozó szerkesztése|Találkozó neve|Találkozó leírása|Találkozó típusa|Kétszemélyes találkozó|Csoportos találkozó|Résztvevők|A találkozó résztvevői|Csatlakozás|Találkozó elhagyása|Hírfolyam|Emberek|Beszélgetések|Profil|Ismerősök|Értesítések|Az alkalmazásról|Visszajelzés|Használati szabályok|Adatvédelmi szabályzat|Felhasználói megállapodás|Nyilvános ajánlat|Hozzászólások|Hozzászólás|Válasz|Válaszok|Üzenet küldése|Hozzászólás küldése|Másolás|Törlés|Szerkesztés|Frissítés|Hozzáadás|Kiválasztás|Fényképek|Fénykép hozzáadása|Profilkép|Keresés becenév alapján|Alkalmazás|Visszaállítás|Értem|Teszt kitöltése|Emlékezzen rám|Elfelejtette jelszavát?|Jelszó visszaállítása|Eredmény ellenőrzése|Küldés ellenőrzése|Előző oldal|Következő oldal|Felhasználó|Beállítások''',
'sv': '''Språk|Stäng|Avbryt|Spara|Försök igen|Försök på nytt|Ja|Nej|Logga in|Inloggning|Registrering|Registrera dig|Logga ut|Lösenord|Upprepa lösenord|Namn|Ålder|Kön|Land|Region|Om mig|Intressen och hobbyer|Längd|Har du barn?|Manligt|Kvinnligt|Män|Kvinnor|Alla|Vilken som helst|Vilken som helst|Alla länder|Alla regioner|Träffar|Skapa träff|Redigera träff|Träffens namn|Beskrivning av träffen|Typ av träff|Träff för två|Gruppträff|Deltagare|Träffens deltagare|Gå med|Lämna träffen|Flöde|Personer|Chattar|Profil|Vänner|Aviseringar|Om appen|Feedback|Användningsregler|Integritetspolicy|Användaravtal|Offentligt anbud|Kommentarer|Kommentar|Svara|Svar|Skicka meddelande|Skicka kommentar|Kopiera|Ta bort|Redigera|Uppdatera|Lägg till|Välj|Foton|Lägg till foto|Profilfoto|Sök på smeknamn|Tillämpa|Återställ|Jag förstår|Gör testet|Kom ihåg mig|Glömt lösenordet?|Återställ lösenord|Kontrollera resultat|Kontrollera sändning|Föregående sida|Nästa sida|Användare|Inställningar''',
'nb': '''Språk|Lukk|Avbryt|Lagre|Prøv igjen|Prøv på nytt|Ja|Nei|Logg inn|Innlogging|Registrering|Registrer deg|Logg ut|Passord|Gjenta passord|Navn|Alder|Kjønn|Land|Region|Om meg|Interesser og hobbyer|Høyde|Har du barn?|Mannlig|Kvinnelig|Menn|Kvinner|Alle|Hvilken som helst|Hvilken som helst|Alle land|Alle regioner|Treff|Opprett treff|Rediger treff|Treffets navn|Beskrivelse av treffet|Type treff|Treff for to|Gruppetreff|Deltakere|Deltakere på treffet|Bli med|Forlat treffet|Innlegg|Personer|Chatter|Profil|Venner|Varsler|Om appen|Tilbakemelding|Bruksregler|Personvernerklæring|Brukeravtale|Offentlig tilbud|Kommentarer|Kommentar|Svar|Svar|Send melding|Send kommentar|Kopier|Slett|Rediger|Oppdater|Legg til|Velg|Bilder|Legg til bilde|Profilbilde|Søk etter kallenavn|Bruk|Tilbakestill|Forstått|Ta testen|Husk meg|Glemt passord?|Tilbakestill passord|Sjekk resultat|Sjekk sending|Forrige side|Neste side|Bruker|Innstillinger''',
'fi': '''Kieli|Sulje|Peruuta|Tallenna|Yritä uudelleen|Yritä uudestaan|Kyllä|Ei|Kirjaudu sisään|Kirjautuminen|Rekisteröityminen|Rekisteröidy|Kirjaudu ulos|Salasana|Toista salasana|Nimi|Ikä|Sukupuoli|Maa|Alue|Tietoja minusta|Kiinnostuksen kohteet ja harrastukset|Pituus|Onko sinulla lapsia?|Mies|Nainen|Miehet|Naiset|Kaikki|Mikä tahansa|Mikä tahansa|Kaikki maat|Kaikki alueet|Tapaamiset|Luo tapaaminen|Muokkaa tapaamista|Tapaamisen nimi|Tapaamisen kuvaus|Tapaamisen tyyppi|Kahdenkeskinen tapaaminen|Ryhmätapaaminen|Osallistujat|Tapaamisen osallistujat|Liity|Poistu tapaamisesta|Syöte|Ihmiset|Keskustelut|Profiili|Ystävät|Ilmoitukset|Tietoja sovelluksesta|Palaute|Käyttösäännöt|Tietosuojakäytäntö|Käyttäjäsopimus|Julkinen tarjous|Kommentit|Kommentti|Vastaa|Vastaukset|Lähetä viesti|Lähetä kommentti|Kopioi|Poista|Muokkaa|Päivitä|Lisää|Valitse|Kuvat|Lisää kuva|Profiilikuva|Hae nimimerkillä|Käytä|Nollaa|Selvä|Tee testi|Muista minut|Unohditko salasanasi?|Palauta salasana|Tarkista tulos|Tarkista lähetys|Edellinen sivu|Seuraava sivu|Käyttäjä|Asetukset''',
'da': '''Sprog|Luk|Annuller|Gem|Prøv igen|Prøv på ny|Ja|Nej|Log ind|Login|Registrering|Opret konto|Log ud|Adgangskode|Gentag adgangskode|Navn|Alder|Køn|Land|Region|Om mig|Interesser og hobbyer|Højde|Har du børn?|Mandligt|Kvindeligt|Mænd|Kvinder|Alle|Vilkårlig|Vilkårlig|Alle lande|Alle regioner|Møder|Opret møde|Rediger møde|Mødets navn|Beskrivelse af mødet|Mødetype|Møde for to|Gruppemøde|Deltagere|Mødets deltagere|Deltag|Forlad mødet|Opslag|Personer|Chats|Profil|Venner|Notifikationer|Om appen|Feedback|Brugsregler|Privatlivspolitik|Brugeraftale|Offentligt tilbud|Kommentarer|Kommentar|Svar|Svar|Send besked|Send kommentar|Kopiér|Slet|Rediger|Opdater|Tilføj|Vælg|Billeder|Tilføj billede|Profilbillede|Søg efter kaldenavn|Anvend|Nulstil|Forstået|Tag testen|Husk mig|Glemt adgangskoden?|Nulstil adgangskode|Tjek resultat|Tjek afsendelse|Forrige side|Næste side|Bruger|Indstillinger''',
'nl': '''Taal|Sluiten|Annuleren|Opslaan|Opnieuw proberen|Nogmaals proberen|Ja|Nee|Inloggen|Inloggen|Registratie|Registreren|Uitloggen|Wachtwoord|Herhaal wachtwoord|Naam|Leeftijd|Geslacht|Land|Regio|Over mij|Interesses en hobby’s|Lengte|Heb je kinderen?|Mannelijk|Vrouwelijk|Mannen|Vrouwen|Alle|Alle|Alle|Alle landen|Alle regio’s|Ontmoetingen|Ontmoeting maken|Ontmoeting bewerken|Naam van de ontmoeting|Beschrijving van de ontmoeting|Soort ontmoeting|Ontmoeting met twee|Groepsontmoeting|Deelnemers|Deelnemers aan de ontmoeting|Deelnemen|Ontmoeting verlaten|Tijdlijn|Mensen|Chats|Profiel|Vrienden|Meldingen|Over de app|Feedback|Gebruiksregels|Privacybeleid|Gebruikersovereenkomst|Openbaar aanbod|Reacties|Reactie|Antwoorden|Antwoorden|Bericht sturen|Reactie plaatsen|Kopiëren|Verwijderen|Bewerken|Vernieuwen|Toevoegen|Selecteren|Foto’s|Foto toevoegen|Profielfoto|Zoeken op bijnaam|Toepassen|Opnieuw instellen|Begrepen|Test doen|Onthoud mij|Wachtwoord vergeten?|Wachtwoord herstellen|Resultaat controleren|Verzending controleren|Vorige pagina|Volgende pagina|Gebruiker|Instellingen''',
'is': '''Tungumál|Loka|Hætta við|Vista|Reyna aftur|Reyna aftur|Já|Nei|Skrá inn|Innskráning|Nýskráning|Nýskrá|Skrá út|Lykilorð|Endurtaktu lykilorð|Nafn|Aldur|Kyn|Land|Svæði|Um mig|Áhugamál og tómstundir|Hæð|Áttu börn?|Karlkyn|Kvenkyn|Karlar|Konur|Allt|Hvaða sem er|Hvaða sem er|Öll lönd|Öll svæði|Samkomur|Búa til samkomu|Breyta samkomu|Heiti samkomu|Lýsing á samkomu|Tegund samkomu|Tveggja manna samkoma|Hópsamkoma|Þátttakendur|Þátttakendur í samkomu|Taka þátt|Yfirgefa samkomu|Færslur|Fólk|Spjall|Prófíll|Vinir|Tilkynningar|Um forritið|Ábendingar|Notkunarreglur|Persónuverndarstefna|Notendasamningur|Opinbert tilboð|Athugasemdir|Athugasemd|Svara|Svör|Senda skilaboð|Senda athugasemd|Afrita|Eyða|Breyta|Endurhlaða|Bæta við|Velja|Myndir|Bæta við mynd|Prófílmynd|Leita eftir gælunafni|Nota|Endurstilla|Skilið|Taka prófið|Muna eftir mér|Gleymt lykilorð?|Endurstilla lykilorð|Athuga niðurstöðu|Athuga sendingu|Fyrri síða|Næsta síða|Notandi|Stillingar''',
})

from l10n_auth import add_auth
add_auth(batch)
from l10n_auth_ui import add_auth_ui
add_auth_ui(batch)
from l10n_counts import add_counts
add_counts(CAT)
from l10n_guide import add_guide
add_guide(batch)
from l10n_social_labels import add_social_labels
add_social_labels(batch)
from l10n_groups import add_groups
add_groups(CAT)
from l10n_profile_labels import add_profile_labels
add_profile_labels(batch)

from l10n_registration_labels import add_registration_labels
add_registration_labels(batch)
from l10n_registration_copy import add_registration_copy
add_registration_copy(batch)
from l10n_draft_copy import add_draft_copy
add_draft_copy(batch)
from l10n_session_copy import add_session_copy
add_session_copy(batch)
from l10n_test_ui import add_test_ui
add_test_ui(batch)
from l10n_final_taglines import add_final_taglines
add_final_taglines(batch)
from l10n_general_ui import add_general_ui
add_general_ui(batch)
from l10n_feed_ui import add_feed_ui
add_feed_ui(batch)
from l10n_more_labels import add_more_labels
add_more_labels(batch)
from l10n_feed_notices import add_feed_notices
add_feed_notices(batch)
from l10n_shop_ui import add_shop_ui
add_shop_ui(batch)
from l10n_system_notifications import add_system_notifications
add_system_notifications(batch)
from l10n_chat_ui import add_chat_ui
add_chat_ui(batch)
from l10n_remaining_labels import add_remaining_labels
add_remaining_labels(batch)
from l10n_final_labels import add_final_labels
add_final_labels(batch, CAT)
from l10n_final_notices import add_final_notices
add_final_notices(batch)
from l10n_errors import add_errors
add_errors(CAT)

for code in CODES:
    CAT[code]['Email'] = 'Email'
    for alias, canonical in {
        'Слишком много попыток. Попробуйте позднее': 'Слишком много попыток. Попробуйте позднее.',
        'Сеанс завершён. Войдите снова': 'Сеанс завершён. Войдите снова.',
        'Нет соединения с сервером.': 'Нет соединения с сервером',
        'Нет аккаунта? ': 'Нет аккаунта?',
        'Обо мне': 'О себе',
        'Редактировать профиль': 'Изменить профиль',
        'Есть': 'Да',
        'Пароль должен содержать не менее 6 символов': 'Пароль должен содержать 6 символов',
        'Электронная почта': 'Email',
        'Фотография {number}': 'Фото {number}',
        'Проверьте email.': 'Проверьте email',
        'в сети': 'В сети',
        'не в сети': 'Не в сети',
        'свободен': 'Свободен',
        'занят': 'Занят',
        'Уже есть аккаунт? ': 'Уже есть аккаунт?',
    }.items():
        CAT[code][alias] = alias if code == 'ru' else CAT[code][canonical]

# Independent contributors may add complete 23-language JSON segments here.
# Shape: {"en": {"Russian UI key": "English translation"}, ... all 23 codes}.
# Drafts must use .draft.json and are intentionally not assembled as translations.
for segment in sorted((ROOT / 'tool/l10n_segments').glob('*.json')):
    if segment.name.endswith('.draft.json'):
        continue
    values = json.loads(segment.read_text())
    assert set(values) == set(CODES), (str(segment), 'requires all 23 languages')
    keys = set(values['ru'])
    for code in CODES:
        assert set(values[code]) == keys, (str(segment), code, 'key mismatch')
        for key, value in values[code].items():
            assert key not in CAT[code] or CAT[code][key] == value, (str(segment), code, key, 'conflicting translation')
            CAT[code][key] = value

# Exact aliases retain Russian source punctuation; translated meaning is identical.
for code in CODES:
    key = 'Не удалось отправить сообщение. Текст сохранён — попробуйте ещё раз.'
    CAT[code][key] = key if code == 'ru' else CAT[code]['Не удалось отправить сообщение. Текст сохранён; попробуйте ещё раз.']
    key = 'Не удалось загрузить страну и регион. Повторить'
    CAT[code][key] = key if code == 'ru' else CAT[code]['Не удалось загрузить страну и регион.'] + ' ' + CAT[code]['Повторить']
    first = 'От компании встречу создаёт один организатор.'
    second = 'Другие участники присоединяются к созданной встрече.'
    CAT[code][first + '\n' + second] = CAT[code][first] + '\n' + CAT[code][second]

from l10n_native_meetings import add_native_meetings
add_native_meetings(batch, CAT)

# Preserve reviewed wording from the delivered native catalogs. These explicit
# overrides are source data, not a fallback to another language or build output.
reviewed = json.loads((ROOT / 'tool/l10n_reviewed_overrides.json').read_text())
assert set(reviewed) == set(CODES)
for code in CODES:
    assert set(reviewed[code]) == set(reviewed['ru'])
    assert all(isinstance(v, str) and v for v in reviewed[code].values())
    CAT[code].update(reviewed[code])

# Additional domain batches follow below. No fallback is written into catalogs.

def write():
    out = ROOT / 'assets/l10n'
    out.mkdir(parents=True, exist_ok=True)
    for code, messages in CAT.items():
        (out / f'{code}.json').write_text(json.dumps(messages, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(CODES)} catalogs, {len(CAT["ru"])} keys each')

if __name__ == '__main__':
    write()
