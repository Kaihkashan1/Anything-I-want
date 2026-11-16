import Foundation

// MARK: - Semantic recipe search
//
// Mirrors the "semantic recipe search" section of app/static/app.js — keep
// the two in step. A query is split into terms (stopwords dropped, known
// multi-word phrases kept whole). Every term has to hit the recipe
// somewhere — title, tags, course, or ingredients — either as typed
// (typo-tolerant), via a synonym (cilantro ≈ coriander, aubergine ≈
// eggplant ≈ brinjal), or via a broader concept ("dessert" finds a
// brownie, "seafood" finds prawns, "vegetarian" finds recipes with no meat
// or fish). Hits rank title over tags over ingredients. Ingredients are
// only searched, never offered as filter chips.

private let searchStopwords: Set<String> = [
    "a", "an", "and", "the", "with", "without", "of", "for", "in", "on", "to", "or",
    "recipe", "recipes", "dish", "dishes", "some", "my", "made", "using", "style",
]

/// Two-way: any member finds any other.
private let searchSynonyms: [[String]] = [
    ["coriander", "cilantro", "dhania"],
    ["eggplant", "aubergine", "brinjal", "baingan"],
    ["chickpea", "garbanzo", "garbanzo bean", "chana", "chole"],
    ["zucchini", "courgette"],
    ["capsicum", "bell pepper"],
    ["scallion", "spring onion", "green onion"],
    ["yogurt", "yoghurt", "curd", "dahi"],
    ["paneer", "cottage cheese"],
    ["potato", "aloo"],
    ["cauliflower", "gobi"],
    ["spinach", "palak"],
    ["okra", "bhindi", "ladyfinger"],
    ["lentil", "dal", "dhal", "daal"],
    ["pea", "matar"],
    ["shrimp", "prawn"],
    ["cornstarch", "cornflour"],
    ["mince", "minced", "ground meat", "keema"],
    ["chili", "chilli", "chile"],
    ["arugula", "rocket"],
    ["beet", "beetroot"],
    ["confectioners sugar", "powdered sugar", "icing sugar"],
    ["mutton", "lamb", "goat"],
    ["noodle", "noodles"],
]

private let conceptDessert = ["dessert", "sweet", "cake", "cookie", "brownie", "pudding", "ice cream", "pie", "tart", "chocolate", "halwa", "kheer", "muffin", "cheesecake", "mousse", "custard", "cupcake", "tiramisu", "fudge", "ladoo", "barfi"]
private let conceptSweet = ["dessert", "cake", "cookie", "brownie", "pudding", "ice cream", "pie", "tart", "chocolate", "halwa", "kheer", "muffin"]
private let conceptPasta = ["pasta", "spaghetti", "penne", "linguine", "fettuccine", "macaroni", "lasagna", "lasagne", "fusilli", "rigatoni", "orzo", "ravioli", "tortellini", "gnocchi", "tagliatelle", "pappardelle"]
private let conceptNoodle = ["ramen", "udon", "soba", "lo mein", "chow mein", "pad thai", "vermicelli", "hakka"]
private let conceptMeat = ["meat", "chicken", "beef", "pork", "lamb", "mutton", "turkey", "bacon", "sausage", "keema", "ham", "steak", "veal", "duck", "goat", "chorizo", "pepperoni", "salami", "prosciutto", "pancetta"]
private let conceptPoultry = ["chicken", "turkey", "duck"]
private let conceptSeafood = ["seafood", "fish", "salmon", "tuna", "cod", "shrimp", "prawn", "crab", "lobster", "mussel", "clam", "squid", "calamari", "scallop", "anchovy", "sardine", "tilapia", "mackerel", "oyster"]
private let conceptFish = ["fish", "salmon", "tuna", "cod", "tilapia", "mackerel", "sardine", "anchovy", "haddock", "trout", "halibut", "sea bass"]
private let conceptSpicy = ["spicy", "chili", "chilli", "jalapeno", "sriracha", "cayenne", "gochujang", "harissa", "habanero", "peri peri", "hot sauce", "vindaloo", "szechuan", "sichuan"]
private let conceptBreakfast = ["breakfast", "egg", "pancake", "oat", "oatmeal", "waffle", "toast", "granola", "omelette", "omelet", "porridge", "smoothie", "poha", "upma", "paratha", "french toast"]
private let conceptSoup = ["soup", "stew", "broth", "ramen", "chowder", "bisque", "rasam", "pho", "minestrone"]
private let conceptBread = ["bread", "naan", "roti", "chapati", "paratha", "focaccia", "loaf", "bun", "bagel", "pita", "brioche", "sourdough", "baguette", "flatbread", "tortilla"]
private let conceptCurry = ["curry", "masala", "korma", "tikka", "vindaloo", "dal", "sabzi", "makhani", "rogan josh", "jalfrezi"]
private let conceptCheese = ["cheese", "paneer", "mozzarella", "parmesan", "cheddar", "feta", "ricotta", "halloumi", "gouda", "brie", "mascarpone", "burrata", "pecorino"]
private let conceptDrink = ["drink", "smoothie", "lassi", "juice", "cocktail", "mocktail", "latte", "tea", "chai", "coffee", "shake", "lemonade"]
private let conceptSnack = ["snack", "chips", "fries", "pakora", "samosa", "nachos", "popcorn", "bites", "fritter", "tikki", "chaat"]
private let conceptSalad = ["salad", "slaw", "coleslaw", "raita"]
private let conceptRice = ["rice", "biryani", "pulao", "pilaf", "risotto", "fried rice", "paella", "khichdi"]

/// One-way: the concept finds its members (searching "cake" doesn't find
/// every dessert). Ordered pairs so the index build is deterministic.
private let searchConcepts: [(String, [String])] = [
    ("dessert", conceptDessert),
    ("sweet", conceptSweet),
    ("pasta", conceptPasta),
    ("noodle", conceptNoodle),
    ("meat", conceptMeat),
    ("poultry", conceptPoultry),
    ("seafood", conceptSeafood),
    ("fish", conceptFish),
    ("spicy", conceptSpicy),
    ("breakfast", conceptBreakfast),
    ("soup", conceptSoup),
    ("bread", conceptBread),
    ("curry", conceptCurry),
    ("cheese", conceptCheese),
    ("drink", conceptDrink),
    ("snack", conceptSnack),
    ("salad", conceptSalad),
    ("rice", conceptRice),
    ("desserts", conceptDessert),
    ("sweets", conceptSweet),
    ("noodles", conceptNoodle),
    ("hot", conceptSpicy),
    ("drinks", conceptDrink),
    ("snacks", conceptSnack),
    ("soups", conceptSoup),
    ("curries", conceptCurry),
]

/// Concepts that describe what's *in* a recipe, so their members are looked
/// for in ingredients too. The rest (dessert, breakfast, soup, …) describe
/// the dish, and only match titles/tags — otherwise every recipe with an
/// egg would count as breakfast.
private let searchIngredientConcepts: Set<String> = [
    "meat", "poultry", "seafood", "fish", "cheese", "pasta", "noodle", "noodles", "spicy", "hot",
]

private let searchDairy = ["milk", "cheese", "butter", "cream", "yogurt", "yoghurt", "curd", "ghee", "paneer", "egg", "honey", "mozzarella", "parmesan", "cheddar", "feta", "ricotta", "mascarpone", "buttermilk"]

/// "Without these" concepts: a recipe matches when none of them show up in
/// its title or ingredients (or when it's tagged with the word itself).
private let searchExclusions: [(String, [String])] = [
    ("vegetarian", conceptMeat + conceptSeafood),
    ("veg", conceptMeat + conceptSeafood),
    ("veggie", conceptMeat + conceptSeafood),
    ("vegan", conceptMeat + conceptSeafood + searchDairy),
    ("plant based", conceptMeat + conceptSeafood + searchDairy),
    ("pescatarian", conceptMeat),
]

/// Lowercased, accents stripped (jalapeño → jalapeno).
private func searchFold(_ text: String) -> String {
    text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
}

/// Crude English plural folding, applied to both the query and the recipe
/// so they only have to agree with each other: tomatoes/tomato → tomato,
/// cookies/cookie → cooky, berries/berry → berry. Words are plain a–z here.
func searchStem(_ word: String) -> String {
    if word.count <= 3 { return word }
    var stem = word
    if stem.hasSuffix("oes") || stem.hasSuffix("ches") || stem.hasSuffix("shes")
        || stem.hasSuffix("sses") || stem.hasSuffix("xes") {
        stem = String(stem.dropLast(2))
    } else if stem.hasSuffix("ies") {
        stem = String(stem.dropLast(1))
    } else if stem.hasSuffix("s"), !stem.hasSuffix("ss"), !stem.hasSuffix("us"), !stem.hasSuffix("is") {
        stem = String(stem.dropLast(1))
    }
    if stem.count > 4, stem.hasSuffix("ie") {
        stem = String(stem.dropLast(2)) + "y"
    }
    return stem
}

/// Runs of a–z (after folding), each stemmed — same as the web's
/// `match(/[a-z]+/g)`.
func searchWords(_ text: String) -> [String] {
    var words: [String] = []
    var current: [UInt8] = []
    for byte in searchFold(text).utf8 {
        if byte >= 97 && byte <= 122 {
            current.append(byte)
        } else if !current.isEmpty {
            words.append(searchStem(String(decoding: current, as: UTF8.self)))
            current.removeAll(keepingCapacity: true)
        }
    }
    if !current.isEmpty {
        words.append(searchStem(String(decoding: current, as: UTF8.self)))
    }
    return words
}

/// Phrase text as stemmed words joined by single spaces, so "Spring Onions"
/// and "spring onion" compare equal.
private func searchPhrase(_ text: String) -> String {
    searchWords(text).joined(separator: " ")
}

private struct SearchConcept {
    let members: [String]
    let inIngredients: Bool
}

/// Built once on first use.
private enum SearchIndex {
    static let synonyms: [String: [String]] = {
        var index: [String: [String]] = [:]
        for group in searchSynonyms {
            let phrases = group.map(searchPhrase)
            for phrase in phrases {
                var merged = index[phrase] ?? []
                for other in phrases where !merged.contains(other) {
                    merged.append(other)
                }
                index[phrase] = merged
            }
        }
        return index
    }()

    static let concepts: [String: SearchConcept] = {
        var index: [String: SearchConcept] = [:]
        for (key, members) in searchConcepts {
            index[searchPhrase(key)] = SearchConcept(
                members: members.map(searchPhrase),
                inIngredients: searchIngredientConcepts.contains(key)
            )
        }
        return index
    }()

    static let exclusions: [String: [String]] = {
        var index: [String: [String]] = [:]
        for (key, members) in searchExclusions {
            index[searchPhrase(key)] = members.map(searchPhrase)
        }
        return index
    }()

    /// Longest multi-word keys first, so "spring onion" is taken whole
    /// before "onion" alone.
    static let multiwordKeys: [[String]] = {
        var seen = Set<String>()
        var keys: [[String]] = []
        for key in Array(synonyms.keys) + Array(concepts.keys) + Array(exclusions.keys) {
            guard key.contains(" "), !seen.contains(key) else { continue }
            seen.insert(key)
            keys.append(key.split(separator: " ").map(String.init))
        }
        return keys.sorted { $0.count > $1.count }
    }()
}

func searchTerms(_ query: String) -> [String] {
    var words = searchWords(query)
    var terms: [String] = []
    // Pull out known phrases first.
    for parts in SearchIndex.multiwordKeys {
        var i = 0
        while i + parts.count <= words.count {
            var matches = true
            for j in 0 ..< parts.count where words[i + j] != parts[j] {
                matches = false
                break
            }
            if matches {
                terms.append(parts.joined(separator: " "))
                words.removeSubrange(i ..< i + parts.count)
            } else {
                i += 1
            }
        }
    }
    for word in words where !searchStopwords.contains(word) {
        terms.append(word)
    }
    var seen = Set<String>()
    return terms.filter { seen.insert($0).inserted }
}

/// Per-recipe precomputed search data, built once when the recipe decodes.
struct RecipeSearchBlob: Hashable {
    let title: [String]
    let titleText: String
    let labels: [String]
    let labelsText: String
    let ingredients: [String]
    let ingredientsText: String

    init(title rawTitle: String, tags: [String], course: String, pantry: [String], ingredients rawIngredients: [String]) {
        title = searchWords(rawTitle)
        titleText = " \(title.joined(separator: " ")) "
        labels = searchWords((tags + [course]).joined(separator: " "))
        labelsText = " \(labels.joined(separator: " ")) "
        ingredients = searchWords((pantry + rawIngredients).joined(separator: " "))
        ingredientsText = " \(ingredients.joined(separator: " ")) "
    }
}

/// An exact-ish hit for a synonym/concept phrase: whole words, or a word
/// that starts with it ("chocolate" in "chocolatey").
private func searchPhraseIn(_ words: [String], _ text: String, _ phrase: String) -> Bool {
    if phrase.contains(" ") { return text.contains(" \(phrase) ") }
    let long = phrase.count >= 4
    return words.contains { $0 == phrase || (long && $0.hasPrefix(phrase)) }
}

/// The typed word itself also tolerates typos. Ingredient/tag words are
/// matched more strictly than titles, so "pea" doesn't find "speak" and
/// "egg" doesn't find "eggplant".
private func searchTypedIn(_ words: [String], _ term: String, loose: Bool) -> Bool {
    if term.contains(" ") { return false }
    let termCount = term.count
    // Short words only typo-match in titles: "rice" ≈ "ice" in an
    // ingredient list is noise, not a typo.
    let allowed = (loose || termCount >= 5) ? typoAllowance(termCount) : 0
    let termFirst = term.first
    for word in words {
        if word == term { return true }
        let wordCount = word.count
        // Half-typed words ("chick" → chicken) — but in ingredients/tags
        // only a short tail, so "egg" doesn't find eggplant.
        if word.hasPrefix(term), loose || wordCount - termCount <= 2 { return true }
        if loose, termCount >= 3, word.contains(term) { return true }
        if allowed > 0,
           word.first == termFirst,
           abs(wordCount - termCount) <= allowed,
           levenshtein(word, term) <= allowed {
            return true
        }
    }
    return false
}

private func scoreSearchTerm(_ blob: RecipeSearchBlob, _ term: String) -> Int {
    if let exclusion = SearchIndex.exclusions[term] {
        if searchPhraseIn(blob.labels, blob.labelsText, term) { return 6 }
        let hit = exclusion.contains { phrase in
            searchPhraseIn(blob.title, blob.titleText, phrase)
                || searchPhraseIn(blob.ingredients, blob.ingredientsText, phrase)
        }
        return hit ? 0 : 3
    }
    let synonyms = (SearchIndex.synonyms[term] ?? []).filter { $0 != term }
    let concept = SearchIndex.concepts[term]
    let conceptMembers = (concept?.members ?? []).filter { $0 != term }
    // (words, text, typed score, related score, loose, concepts apply)
    let fields: [([String], String, Int, Int, Bool, Bool)] = [
        (blob.title, blob.titleText, 10, 7, true, true),
        (blob.labels, blob.labelsText, 6, 4, false, true),
        (blob.ingredients, blob.ingredientsText, 4, 3, false, concept?.inIngredients ?? false),
    ]
    var best = 0
    for (words, text, typed, relatedScore, loose, useConcepts) in fields {
        if typed > best,
           searchPhraseIn(words, text, term) || searchTypedIn(words, term, loose: loose) {
            best = typed
        }
        if relatedScore <= best { continue }
        let related = useConcepts ? synonyms + conceptMembers : synonyms
        if related.contains(where: { searchPhraseIn(words, text, $0) }) {
            best = relatedScore
        }
    }
    return best
}

/// 0 = no match. Every term has to land somewhere; a run-together or
/// typo'd title (the old title-only matcher) still counts.
func recipeSearchScore(_ recipe: Recipe, query: String) -> Int {
    let titleHit = recipeTitleMatches(recipe.title, query: query) ? 15 : 0
    let terms = searchTerms(query)
    if terms.isEmpty { return titleHit }
    var total = 0
    for term in terms {
        let score = scoreSearchTerm(recipe.searchBlob, term)
        if score == 0 { return titleHit }
        total += score
    }
    return total + titleHit
}
