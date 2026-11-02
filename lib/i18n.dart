import 'package:flutter/foundation.dart';

/// Current UI language: 'fr' (default), 'en' or 'ar'.
final appLang = ValueNotifier<String>('fr');

/// French text (also the field keys coming from the chip reader) → [en, ar].
const _t = <String, List<String>>{
  // Screen
  'Données d\'accès à la puce': ['Chip access data', 'بيانات الوصول إلى الشريحة'],
  'Scannez la MRZ ou recopiez-les depuis la carte, puis posez la carte sur le lecteur.': [
    'Scan the MRZ or copy them from the card, then place the card on the reader.',
    'امسح منطقة MRZ أو انسخها من البطاقة، ثم ضع البطاقة على القارئ.',
  ],
  'Choisir…': ['Choose…', 'اختر…'],
  'Scanner la carte': ['Scan the card', 'مسح البطاقة'],
  'En attente du scan…': ['Waiting for scan…', 'في انتظار المسح…'],
  'Passez la zone MRZ du document sous la douchette.': [
    'Scan the document\'s MRZ zone with the handheld scanner.',
    'امسح منطقة MRZ للوثيقة بالماسح اليدوي.',
  ],
  'Annuler': ['Cancel', 'إلغاء'],
  'Posez la carte sur le lecteur': ['Place the card on the reader', 'ضع البطاقة على القارئ'],
  'À plat, sur le dessus du lecteur sans contact : la lecture démarre toute seule.': [
    'Flat, on top of the contactless reader: reading starts by itself.',
    'بشكل مسطّح فوق القارئ اللاتلامسي: تبدأ القراءة تلقائياً.',
  ],
  'Lecture réussie': ['Read successful', 'تمت القراءة بنجاح'],
  'Attention': ['Attention', 'تنبيه'],
  'Scannez la MRZ avec la douchette, ou saisissez le numéro et les dates.': [
    'Scan the MRZ with the handheld scanner, or type the number and dates.',
    'امسح منطقة MRZ بالماسح اليدوي، أو أدخل الرقم والتاريخين.',
  ],
  'Posez la carte à plat sur le lecteur sans contact.': [
    'Lay the card flat on the contactless reader.',
    'ضع البطاقة بشكل مسطّح على القارئ اللاتلامسي.',
  ],
  'Vérifiez les informations puis imprimez la fiche.': [
    'Check the information, then print the sheet.',
    'تحقّق من المعلومات ثم اطبع البطاقة.',
  ],
  "Ce code n'est pas une MRZ (code QR ?) : visez les lignes MRZ en bas du document.": [
    'This code is not an MRZ (QR code?): aim at the MRZ lines at the bottom of the document.',
    'هذا الرمز ليس منطقة MRZ (رمز QR؟): وجّه الماسح إلى أسطر MRZ أسفل الوثيقة.',
  ],
  'Lire la carte': ['Read card', 'قراءة البطاقة'],
  'Lecture en cours…': ['Reading…', 'جارٍ القراءة…'],
  'Imprimer': ['Print', 'طباعة'],
  'Aucune carte lue': ['No card read', 'لم تتم قراءة أي بطاقة'],
  'Saisissez le numéro et choisissez les deux dates.': [
    'Enter the number and choose both dates.',
    'أدخل الرقم واختر التاريخين.',
  ],
  "Cette puce ne contient pas les données d'identité : posez la carte À PLAT sur le dessus du lecteur (sans contact), pas dans la fente.": [
    'This chip does not hold the identity data: lay the card FLAT on top of the reader (contactless), not in the slot.',
    'هذه الشريحة لا تحتوي على بيانات الهوية: ضع البطاقة مسطّحة فوق القارئ (دون تلامس) وليس داخل الفتحة.',
  ],
  'Le lecteur ne répond pas : retirez la carte, réinsérez-la et réessayez.': [
    'The reader is not responding: remove the card, insert it again and retry.',
    'القارئ لا يستجيب: أخرج البطاقة ثم أعد إدخالها وحاول مجدداً.',
  ],
  'Lecture impossible : posez la carte sur le lecteur et réessayez.': [
    'Cannot read: place the card on the reader and try again.',
    'تعذّرت القراءة: ضع البطاقة على القارئ وأعد المحاولة.',
  ],
  'Télécharger': ['Download', 'تنزيل'],
  'Fermer': ['Close', 'إغلاق'],
  'Enregistré :': ['Saved:', 'تم الحفظ:'],
  'Afficher': ['Show', 'عرض'],
  'Échec de l\'enregistrement :': ['Save failed:', 'فشل الحفظ:'],
  // PDF
  'Informations biométriques': ['Biometric information', 'المعلومات البيومترية'],
  'Lues depuis la puce du document le': ['Read from the document chip on', 'مقروءة من شريحة الوثيقة بتاريخ'],
  'Photo indisponible': ['Photo unavailable', 'الصورة غير متوفرة'],
  // Fields
  'Nom': ['Surname', 'اللقب'],
  'Prénom(s)': ['Given name(s)', 'الاسم'],
  'N° de document': ['Document number', 'رقم الوثيقة'],
  'Type de document': ['Document type', 'نوع الوثيقة'],
  'Pays émetteur': ['Issuing country', 'بلد الإصدار'],
  'Nationalité': ['Nationality', 'الجنسية'],
  'Date de naissance': ['Date of birth', 'تاريخ الميلاد'],
  'Sexe': ['Sex', 'الجنس'],
  'Date d\'expiration': ['Expiry date', 'تاريخ انتهاء الصلاحية'],
  'Données complémentaires': ['Additional data', 'بيانات إضافية'],
  'Nom complet': ['Full name', 'الاسم الكامل'],
  'Autre(s) nom(s)': ['Other name(s)', 'أسماء أخرى'],
  'N° personnel': ['Personal number', 'الرقم الشخصي'],
  'Date de naissance (complète)': ['Full date of birth', 'تاريخ الميلاد الكامل'],
  'Lieu de naissance': ['Place of birth', 'مكان الميلاد'],
  'Adresse': ['Address', 'العنوان'],
  'Téléphone': ['Telephone', 'الهاتف'],
  'Profession': ['Profession', 'المهنة'],
  'Titre': ['Title', 'الصفة'],
  'Résumé personnel': ['Personal summary', 'ملخص شخصي'],
  'Autres documents de voyage': ['Other travel documents', 'وثائق سفر أخرى'],
  'Informations de garde': ['Custody information', 'معلومات الحضانة'],
  'Autorité de délivrance': ['Issuing authority', 'جهة الإصدار'],
  'Date de délivrance': ['Date of issue', 'تاريخ الإصدار'],
  'Autres personnes': ['Other persons', 'أشخاص آخرون'],
  'Mentions / observations': ['Endorsements / observations', 'ملاحظات'],
  'Taxes / sortie': ['Tax / exit requirements', 'الضرائب / الخروج'],
  'Date de personnalisation': ['Personalisation date', 'تاريخ التخصيص'],
  'N° du système de personnalisation': ['Personalisation system number', 'رقم نظام التخصيص'],
  'Groupe sanguin': ['Blood group', 'فصيلة الدم'],
  'Empreintes / iris': ['Fingerprints / iris', 'البصمات / القزحية'],
  'Photo': ['Photo', 'الصورة'],
  'Signature': ['Signature', 'التوقيع'],
  'Preuve de citoyenneté': ['Proof of citizenship', 'إثبات الجنسية'],
  'Image recto': ['Front image', 'صورة الوجه الأمامي'],
  'Image verso': ['Back image', 'صورة الوجه الخلفي'],
  '(arabe)': ['(Arabic)', '(بالعربية)'],
  'Donnée': ['Data', 'بيانات'],
  // Values
  'Masculin': ['Male', 'ذكر'],
  'Féminin': ['Female', 'أنثى'],
  'Non précisé': ['Unspecified', 'غير محدد'],
  'Passeport': ['Passport', 'جواز سفر'],
  'Carte d\'identité': ['Identity card', 'بطاقة التعريف'],
  'Visa': ['Visa', 'تأشيرة'],
  'Présents mais protégés (EAC) : lecture réservée aux autorités émettrices': [
    'Present but protected (EAC): readable only by the issuing authorities',
    'موجودة لكنها محمية (EAC): القراءة مخصصة لجهات الإصدار',
  ],
};

final _numbered = RegExp(r'^(.*) (\S+)$');

/// Translates a French UI text, field label or value into the current
/// language; unknown text (card data, reader errors) is returned unchanged.
String tr(String fr) {
  final lang = appLang.value;
  if (lang == 'fr') return fr;
  final hit = _t[fr];
  if (hit != null) return hit[lang == 'en' ? 0 : 1];
  if (fr.endsWith(' (arabe)')) return '${tr(fr.substring(0, fr.length - 8))} ${tr('(arabe)')}';
  // "Donnée 5F99", "Signature 2"
  final m = _numbered.firstMatch(fr);
  if (m != null && _t.containsKey(m[1])) return '${tr(m[1]!)} ${m[2]}';
  return fr;
}
