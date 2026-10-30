import SwiftUI

/// Public contact details are configured for each distribution. Never substitute
/// an invented address or claim that an unpublished policy is available online.
struct PublicationInfo {
    let values:[String:String]
    init(bundle:Bundle = .main) {
        if let url=bundle.url(forResource:"Publication",withExtension:"plist"),
           let data=try? Data(contentsOf:url),
           let value=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:String] {values=value}
        else {values=[:]}
    }
    var publisher:String? {let value=values["PublisherName"]?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "";return value.isEmpty ? nil:value}
    func webURL(_ key:String)->URL? {
        guard let raw=values[key],let url=URL(string:raw),url.scheme=="https",let host=url.host,!host.isEmpty,url.user==nil,url.password==nil else{return nil}
        return url
    }
    var emailURL:URL? {
        guard let raw=values["SupportEmail"],raw.range(of:#"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,options:.regularExpression) != nil else{return nil}
        var parts=URLComponents();parts.scheme="mailto";parts.path=raw
        return parts.url
    }
}

struct PrivacyDetailsView:View {
    private let info=PublicationInfo()
    var body:some View {
        Form {
            Section("Biblioteca") {
                Text("Tus juegos, partidas, portadas, skins y preferencias se guardan en este dispositivo. No necesitas crear una cuenta de VETA.")
                Text("Puedes borrar juegos y skins desde sus galerías. Las copias que exportes y los originales en Archivos se gestionan por separado.")
            }
            Section("Portadas") {
                if ArtworkDistributionPolicy.allowsRemoteCovers {
                Text("La búsqueda de portadas consulta GitHub y Libretro Thumbnails. El proveedor recibe las solicitudes de catálogo e imágenes y tu dirección IP; no se suben tus ROMs ni partidas. Puedes desactivarla en Ajustes.")
                } else {
                    Text("PNG, JPEG, HEIC y otras imágenes compatibles, hasta 30 MB. Se guarda una copia optimizada, sin recortar la portada.")
                }
            }
            Section("Conectar mi nube") {
                Text("Conectar una cuenta es opcional. VETA no recibe tu contraseña.")
                Text("Permiso de lectura: VETA explora tus carpetas y descarga tu selección. No modifica archivos en la nube.")
                Text("Los tokens se guardan en el llavero de este iPhone. No enviamos tus juegos ni tus datos de nube a Krafify.")
                Text("Desconectar conserva tus juegos. También puedes revocar el permiso desde tu proveedor.")
                CloudPrivacyLinks()
            }
            Section("Abrir enlace compartido") {
                Text("Si eliges Recordar acceso, el enlace y la contraseña se guardan en el llavero de este iPhone. Puedes eliminarlos con Olvidar acceso.")
                Text("VETA comprueba el acceso al volver a conectar. Si cambia la contraseña del enlace, tendrás que ingresar la nueva. Los juegos ya importados se conservan.")
            }
            Section("Juegos gratis") {
                Text("Al descargar un juego o abrir una guía, el sitio del autor o proveedor recibe la conexión. Sus condiciones de privacidad se aplican en ese sitio.")
            }
            Section("Apoyar VETA") {
                Text("Los aportes voluntarios se procesan mediante compras de Apple. VETA verifica y finaliza la transacción en el dispositivo; no recibe tus datos de tarjeta ni envía tus juegos o partidas para realizar el aporte.")
            }
            Section("Jugar juntos") {
                Text("La conexión cercana comparte un nombre aleatorio de VETA y los controles con los jugadores conectados. Compartir un skin o respaldo sólo ocurre cuando tú lo eliges.")
            }
            #if VETA_EMBEDDED_JIT
            Section("Consolas avanzadas") {
                Text("Si activas JIT, VETA guarda el emparejamiento en este dispositivo y utiliza una VPN local para comunicarse con iOS. No es un servicio VPN para navegar por Internet.")
            }
            #endif
            Section {
                Text("VETA no incorpora anuncios ni un servicio propio de analítica. Las copias del dispositivo y los informes de diagnóstico de Apple dependen de tus ajustes de iOS.")
                if let url=info.webURL("PrivacyPolicyURL") {Link("Política de privacidad",destination:url)}
                if let name=info.publisher {Text(name)}
            }
        }.navigationTitle("Privacidad y datos").navigationBarTitleDisplayMode(.inline)
    }
}

struct CloudPrivacyLinks: View {
    var body: some View {
        Link("Privacidad de VETA", destination: URL(string: "https://retro.krafify.com/privacidad#nube")!)
        Link("Uso y licencias de VETA", destination: URL(string: "https://retro.krafify.com/uso")!)
        Link("Google Drive · Privacidad", destination: URL(string: "https://policies.google.com/privacy")!)
        Link("Google Drive · Condiciones", destination: URL(string: "https://policies.google.com/terms")!)
        Link("OneDrive · Privacidad", destination: URL(string: "https://privacy.microsoft.com/privacystatement")!)
        Link("OneDrive · Condiciones", destination: URL(string: "https://www.microsoft.com/servicesagreement")!)
        Link("Dropbox · Privacidad", destination: URL(string: "https://www.dropbox.com/privacy")!)
        Link("Dropbox · Condiciones", destination: URL(string: "https://www.dropbox.com/terms")!)
    }
}

struct PublicationSupportView:View {
    private let info=PublicationInfo()
    var body:some View {
        Form {
            Section {
                NavigationLink("Cómo crear y usar un skin") {PersonalSkinHelpView()}.accessibilityIdentifier("skin-help")
                Text("Para pedir ayuda, indica la versión de VETA, el modelo de iPhone, la consola y los pasos del problema. No envíes juegos, BIOS, contraseñas ni archivos de emparejamiento.")
                Text("VETA Retro · \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""))").textSelection(.enabled)
            }
            if info.webURL("SupportURL") != nil || info.emailURL != nil {
                Section("Contacto") {
                    if let url=info.webURL("SupportURL") {Link("Centro de soporte",destination:url)}
                    if let url=info.emailURL {Link("Contactar por correo",destination:url)}
                    if let name=info.publisher {Text(name)}
                }
            }
        }.navigationTitle("Ayuda y soporte").navigationBarTitleDisplayMode(.inline)
    }
}

struct GameRightsView:View {
    var body:some View {
        Form {
            Section {
                Text("Importa sólo juegos, BIOS e imágenes que tengas derecho a usar. Una descarga gratuita no concede por sí sola permiso para redistribuirla.")
                Text("VETA es un proyecto independiente y no representa a los fabricantes de las consolas. Consulta las licencias de los motores y del contenido en Créditos.")
            }
        }.navigationTitle("Uso de juegos y licencias").navigationBarTitleDisplayMode(.inline)
    }
}
