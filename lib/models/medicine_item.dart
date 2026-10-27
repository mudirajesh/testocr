class MedicineItem {
  const MedicineItem({
    required this.gtin,
    required this.name,
    required this.strength,
    this.dosageForm = 'Tablet',
    this.manufacturer,
  });

  final String gtin;
  final String name;
  final String strength;
  final String dosageForm;
  final String? manufacturer;

  String get displayName => '$name $strength';
}
