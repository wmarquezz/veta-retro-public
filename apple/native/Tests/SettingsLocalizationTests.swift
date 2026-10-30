import XCTest
@testable import VetaNative

final class SettingsLocalizationTests: XCTestCase {
    func testDynamicSettingsChoicesExistInEveryCatalog() {
        let keys = FeatureAccess.catalog.map(\.title)
            + FeatureClassification.allCases.map(\.title)
            + ControllerSkinPalette.allCases.map(\.rawValue)
            + ControllerSkinOrientation.allCases.map(\.title)
            + TVImageMode.allCases.map(\.title)
            + TVRenderQuality.allCases.map(\.title)
            + VideoFilter.allCases.map(\.title)
            + DSScreenLayout.allCases.map(\.title)
        for language in AppLanguage.allCases {
            let catalog = L10n.catalog(language)
            for key in keys { XCTAssertNotNil(catalog[key], "\(language.rawValue): \(key)") }
        }
    }
    func testEditorNamesAreTranslatedWithoutChangingButtonIDs() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(L10n.controlName("dpad", language: language), L10n.text("Cruceta", language: language))
            XCTAssertNotEqual(L10n.controlName("stick0", language: language), "stick0")
            XCTAssertNotEqual(L10n.controlName("stick1", language: language), "stick1")
            XCTAssertNotEqual(L10n.controlName("SHAKE", language: language), "SHAKE")
            for legend in ["A", "B", "START", "SELECT", "C←", "HOME"] {
                XCTAssertEqual(L10n.controlName(legend, language: language), legend)
            }
        }
    }
    func testSettingsHelpDoesNotFallBackToSpanish() {
        let keys = ["Posición y tamaño", "Posición y tamaño de los controles", "Código fuente · VETA Retro",
            "Mueve y agranda los controles: su dibujo y su zona táctil cambian juntos. Toca Guardar arriba para aplicarlo al juego.",
            "Toca Guardar arriba: guarda y aplica el diseño en la orientación que estás editando. La otra orientación conserva su selección.",
            "Exporta el archivo .vetaskin. En el otro iPhone, elige la misma consola, toca Importar skin compartido y después toca Guardar."]
        for language in AppLanguage.allCases where language != .spanish {
            for key in keys { XCTAssertNotEqual(L10n.text(key,language:language),key,"\(language.rawValue): \(key)") }
        }
    }
    func testLocalizedPercentagesRenderTheirValues() {
        for language in AppLanguage.allCases {
            for key in ["Tamaño %lld %%", "Separación %lld %%", "Opacidad %lld %%"] {
                let result=L10n.format(key,115,language:language)
                XCTAssertTrue(result.contains("115"),result)
                XCTAssertTrue(result.contains("%"),result)
                XCTAssertFalse(result.contains("lld"),result)
            }
        }
    }
    func testInfoPlistPermissionsExistInAllEightLanguages() throws {
        let base = try XCTUnwrap(Bundle.main.url(forResource:"InfoPlist",withExtension:"strings",subdirectory:nil,localization:"es"))
        let expected = try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:base),format:nil) as? [String:String])
        for language in AppLanguage.allCases {
            let url=try XCTUnwrap(Bundle.main.url(forResource:"InfoPlist",withExtension:"strings",subdirectory:nil,localization:language.rawValue))
            let values=try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:url),format:nil) as? [String:String])
            XCTAssertEqual(Set(values.keys),Set(expected.keys))
            XCTAssertFalse(values.values.contains(where:{$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}))
        }
    }
}
