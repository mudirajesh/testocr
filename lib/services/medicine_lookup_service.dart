import '../models/medicine_item.dart';

/// In-app medicine database and lookup service.
/// Matches by GTIN (barcode AI 01 / EAN), exact barcode, or text recognition keywords.
class MedicineLookupService {
  const MedicineLookupService();

  static const List<MedicineItem> _catalog = [
    MedicineItem(
      gtin: '08901083000018',
      name: 'Paracetamol',
      strength: '500 mg',
      dosageForm: 'Tablet',
      manufacturer: 'GSK',
    ),
    MedicineItem(
      gtin: '08901083000025',
      name: 'Paracetamol',
      strength: '650 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Micro Labs',
    ),
    MedicineItem(
      gtin: '08901083000032',
      name: 'Amoxicillin',
      strength: '500 mg',
      dosageForm: 'Capsule',
      manufacturer: 'Cipla',
    ),
    MedicineItem(
      gtin: '08901083000049',
      name: 'Amoxicillin',
      strength: '250 mg',
      dosageForm: 'Capsule',
      manufacturer: 'Cipla',
    ),
    MedicineItem(
      gtin: '08901083000056',
      name: 'Ibuprofen',
      strength: '400 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Abbott',
    ),
    MedicineItem(
      gtin: '08901083000063',
      name: 'Ibuprofen',
      strength: '200 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Abbott',
    ),
    MedicineItem(
      gtin: '08901083000070',
      name: 'Cetirizine',
      strength: '10 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Dr. Reddy',
    ),
    MedicineItem(
      gtin: '08901083000087',
      name: 'Metformin',
      strength: '500 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Sun Pharma',
    ),
    MedicineItem(
      gtin: '08901083000094',
      name: 'Metformin',
      strength: '850 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Sun Pharma',
    ),
    MedicineItem(
      gtin: '08901083000100',
      name: 'Pantoprazole',
      strength: '40 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Alkem',
    ),
    MedicineItem(
      gtin: '08901083000117',
      name: 'Omeprazole',
      strength: '20 mg',
      dosageForm: 'Capsule',
      manufacturer: 'Torrent',
    ),
    MedicineItem(
      gtin: '08901083000124',
      name: 'Azithromycin',
      strength: '500 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Lupin',
    ),
    MedicineItem(
      gtin: '08901083000131',
      name: 'Atorvastatin',
      strength: '20 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Zydus',
    ),
    MedicineItem(
      gtin: '08901083000148',
      name: 'Atorvastatin',
      strength: '10 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Zydus',
    ),
    MedicineItem(
      gtin: '08901083000155',
      name: 'Ciprofloxacin',
      strength: '500 mg',
      dosageForm: 'Tablet',
      manufacturer: 'Bayer',
    ),
  ];

  /// Looks up a medicine by GTIN, raw barcode, or text search.
  MedicineItem? lookup({String? gtin, String? rawBarcode, String? text}) {
    // 1. Exact GTIN match
    if (gtin != null && gtin.isNotEmpty) {
      final cleanGtin = gtin.trim().padLeft(14, '0');
      for (final item in _catalog) {
        if (item.gtin == cleanGtin || cleanGtin.endsWith(item.gtin)) {
          return item;
        }
      }
    }

    // 2. Barcode match
    if (rawBarcode != null && rawBarcode.isNotEmpty) {
      for (final item in _catalog) {
        if (rawBarcode.contains(item.gtin)) {
          return item;
        }
      }
    }

    // 3. Text search (from OCR or label)
    if (text != null && text.isNotEmpty) {
      final lower = text.toLowerCase();
      // First look for name + strength match
      for (final item in _catalog) {
        if (lower.contains(item.name.toLowerCase()) &&
            lower.contains(item.strength.toLowerCase().replaceAll(' ', ''))) {
          return item;
        }
      }
      // Then look for name match
      for (final item in _catalog) {
        if (lower.contains(item.name.toLowerCase())) {
          return item;
        }
      }
    }

    return null;
  }
}
