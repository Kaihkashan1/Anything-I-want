from app import store


def test_pantry_item_keeps_every_real_aisle_and_drops_other():
    item = store._normalize_pantry_item(
        {"name": "Milk", "categories": ["Other", "Dairy & eggs", "dairy & EGGS", "Not an aisle"]}
    )
    assert item["categories"] == ["Dairy & eggs"]
    assert item["category"] == "Dairy & eggs"


def test_pantry_item_legacy_single_category_still_works():
    item = store._normalize_pantry_item({"name": "Rice", "category": "Other"})
    assert item["categories"] == ["Other"]
    assert item["category"] == "Other"


def test_medicine_item_multiple_categories_first_is_primary():
    item = store._normalize_medicine_item(
        {"name": "Ibuprofen", "categories": ["Pain relief", "Fever & cold", "Travel kit"]}
    )
    assert item["categories"] == ["Pain relief", "Fever & cold", "Travel kit"]
    assert item["category"] == "Pain relief"


def test_medicine_item_defaults_to_other():
    item = store._normalize_medicine_item({"name": "Plasters"})
    assert item["categories"] == ["Other"]


def test_save_medicines_registers_every_new_category(monkeypatch):
    state = {}
    monkeypatch.setattr(store, "_read_app_state", lambda: state)
    monkeypatch.setattr(store, "_write_app_state", lambda **updates: state.update(updates))
    items, names = store.save_medicines(
        [{"id": "1", "name": "Ibuprofen", "categories": ["Pain relief", "Travel kit"]}]
    )
    assert items[0]["categories"] == ["Pain relief", "Travel kit"]
    assert "Travel kit" in names and names[-1] == "Other"
