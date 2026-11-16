from app import store


def test_pantry_item_keeps_custom_categories_and_drops_other():
    item = store._normalize_pantry_item(
        {"name": "Crisps", "categories": ["Other", "dairy & EGGS", "Dairy & eggs", "  Snacks  "]}
    )
    assert item["categories"] == ["Dairy & eggs", "Snacks"]
    assert item["category"] == "Dairy & eggs"


def test_pantry_item_without_any_category_is_guessed_from_name():
    item = store._normalize_pantry_item({"name": "Milk"})
    assert item["categories"] == ["Dairy & eggs"]


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


def test_save_pantry_inventory_keeps_custom_categories(monkeypatch):
    state = {}
    monkeypatch.setattr(store, "_read_app_state", lambda: state)
    monkeypatch.setattr(store, "_write_app_state", lambda **updates: state.update(updates))
    result = store.save_pantry_inventory([{"id": "1", "name": "Crisps", "categories": ["Snacks"]}])
    assert result["items"][0]["categories"] == ["Snacks"]
    assert "Snacks" in result["categories"]
    assert "Vegetables" in result["categories"]  # built-in aisles stay
    assert result["categories"][-1] == "Other"
    # A client list replaces the saved one (that's how delete/rename work),
    # but categories items still use are never lost.
    result = store.save_pantry_inventory(
        [{"id": "1", "name": "Crisps", "categories": ["Snacks"]}], categories=["Baking", "Other"]
    )
    assert result["categories"] == ["Baking", "Snacks", "Other"]
    assert store.get_pantry_categories() == ["Baking", "Snacks", "Other"]
