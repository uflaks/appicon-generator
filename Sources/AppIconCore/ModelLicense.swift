import Foundation

/// What a model's licence says about using the images it generates in your own app.
///
/// These are hand-written summaries of the licence texts as read on 17 November 2026.
/// They describe the model's own licence; a hosting provider's terms may apply as well.
public struct ModelLicense: Sendable, Hashable {
    public enum CommercialUse: Sendable, Hashable {
        /// No restriction on commercial use.
        case unrestricted
        /// Allowed, but only while a stated condition holds.
        case conditional
        /// The model is non-commercial, but its licence lets generated images be used commercially.
        case imagesOnly
        /// Generated images may not be used in or for revenue-generating products.
        case notAllowed
        /// A proprietary service; the provider's terms of use decide.
        case providerTerms

        /// A few words for a badge or table cell.
        public var label: String {
            switch self {
            case .unrestricted: "Commercial use OK"
            case .conditional: "Commercial use with a limit"
            case .imagesOnly: "Images OK commercially"
            case .notAllowed: "Non-commercial only"
            case .providerTerms: "Provider's terms"
            }
        }
    }

    public let name: String
    public let commercialUse: CommercialUse
    /// One sentence on what this means for shipping a generated icon in an app.
    public let summary: String
    public let url: URL

    public static let apache2 = ModelLicense(
        name: "Apache 2.0", commercialUse: .unrestricted,
        summary: "Open-source licence with no restriction on using the icons commercially.",
        url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)

    public static let krea2Community = ModelLicense(
        name: "Krea 2 Community License", commercialUse: .conditional,
        summary: "Commercial use is allowed only while your total annual revenue is under 1 million US dollars; above that you need an enterprise licence from Krea.",
        url: URL(string: "https://krea.ai/krea-2-licensing")!)

    public static let flux1DevNonCommercial = ModelLicense(
        name: "FLUX.1 [dev] Non-Commercial License", commercialUse: .imagesOnly,
        summary: "The model itself is for non-commercial use, but its licence lets you use the generated icons for any purpose, including commercially.",
        url: URL(string: "https://huggingface.co/black-forest-labs/FLUX.1-dev/blob/main/LICENSE.md")!)

    public static let fluxNonCommercial = ModelLicense(
        name: "FLUX Non-Commercial License", commercialUse: .imagesOnly,
        summary: "The model itself is for non-commercial use, but its licence lets you use the generated icons for any purpose, including commercially.",
        url: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/blob/main/LICENSE.md")!)

    public static let ideogramNonCommercial = ModelLicense(
        name: "Ideogram Non-Commercial Model Agreement", commercialUse: .notAllowed,
        summary: "Non-commercial only: its icons may not be included in, or used to promote, a product or service that earns revenue.",
        url: URL(string: "https://huggingface.co/ideogram-ai/ideogram-4-fp8/blob/main/LICENSE.md")!)

    public static let openAI = ModelLicense(
        name: "OpenAI terms of use", commercialUse: .providerTerms,
        summary: "A proprietary service, not an open model; OpenAI's terms of use govern what you may do with the icons.",
        url: URL(string: "https://openai.com/policies/terms-of-use")!)
}
