import UIKit
import Vision

/// Checks on the phone that a photo shows food (or, where photos inside aren't allowed,
/// a building or sign), using Apple's built-in image classifier.
enum PhotoChecker {
    enum Subject {
        case food, storefront
    }

    /// Words in Apple's image labels that count for each kind of photo.
    private static let foodWords = [
        "food", "meal", "dish", "drink", "beverage", "coffee", "tea", "dessert", "baked", "bread", "pizza",
        "burger", "hamburger", "sandwich", "salad", "soup", "sushi", "fruit", "vegetable", "snack", "cake",
        "ice_cream", "pastry", "noodle", "pasta", "taco", "burrito", "fries", "seafood", "meat", "breakfast",
        "donut", "doughnut", "bagel", "cookie", "chocolate", "rice", "egg", "cheese", "sausage", "chicken",
        "steak", "dumpling", "pancake", "waffle", "pie", "juice", "smoothie", "beer", "wine", "cocktail",
        "plate", "bowl", "cup", "mug", "bottle", "tableware", "utensil",
    ]
    private static let storefrontWords = [
        "building", "structure", "storefront", "store", "shop", "sign", "signage", "restaurant", "street",
        "city", "window", "door", "architecture", "facade", "house", "awning", "billboard", "shopping",
    ]

    /// The lowest confidence a matching label needs.
    private static let threshold: Float = 0.2

    static func looksRight(_ image: UIImage, for subject: Subject) async -> Bool {
        let labels = await classify(image)
        let words = subject == .food ? foodWords : storefrontWords
        return labels.contains { label in
            label.confidence >= threshold && words.contains { label.identifier.lowercased().contains($0) }
        }
    }

    private static func classify(_ photo: UIImage) async -> [(identifier: String, confidence: Float)] {
        let image = ImageResizer.downscale(photo, maxSide: 1200)
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let labels = (request.results ?? []).map { (identifier: $0.identifier, confidence: $0.confidence) }
                continuation.resume(returning: labels)
            }
        }
    }
}
