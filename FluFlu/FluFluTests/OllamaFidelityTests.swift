import Testing
@testable import FluFlu

struct OllamaFidelityTests {
    @Test(arguments: [
        ("eh bueno tenemos 12 tareas", "Tenemos 12 tareas."),
        ("hola como estas", "Hola, ¿cómo estás?"),
        ("eh eh mm", ""),
        ("usa post gres para esto", "Usa PostgreSQL para esto."),
        ("visita https://example.com/api y abre /tmp/datos.json", "Visita https://example.com/api y abre /tmp/datos.json."),
        ("no quiero borrar esto", "No quiero borrar esto."),
        ("I don't want this", "I don’t want this."),
        ("I cannot delete this", "I can't delete this."),
        ("I can’t delete this", "I cannot delete this."),
        ("usa userID y apiKey", "Usa userID y apiKey."),
        ("usa el identificador", "Usa el userID."),
        // Limpiezas legítimas que el filtro rechazaba (2026-11-13): cambia la grafía, no el contenido.
        ("mándaselo a juan no perdón a marta mañana por la mañana", "Mándaselo a Marta mañana por la mañana."),
        ("lo vemos el lunes ¿no? y cerramos", "Lo vemos el lunes y cerramos."),
        ("necesito veinte unidades para el lunes", "Necesito 20 unidades para el lunes."),
        ("tengo 3 reuniones hoy", "Tengo tres reuniones hoy."),
        ("son 1000 euros al mes", "Son 1.000 euros al mes."),
        ("sube un 5 % cada año", "Sube un 5% cada año."),
        ("quedamos a las 10 30 en la oficina", "Quedamos a las 10:30 en la oficina."),
        ("mide 2,5 metros", "Mide 2.5 metros."),
        ("lo probé en el iphone y en mac os", "Lo probé en el iPhone y en macOS."),
        ("hicimos fine tuning del modelo on device", "Hicimos fine-tuning del modelo on-device."),
        ("va bien en el m1 pro", "Va bien en el M1 Pro."),
        ("compara gpt 4 con claude", "Compara GPT-4 con Claude.")
    ])
    func permitsEditing(raw: String, cleaned: String) {
        #expect(CleanupGuard.preservesProtectedContent(cleaned: cleaned, raw: raw, vocabulary: ["PostgreSQL", "userID"]))
    }

    @Test(arguments: [
        ("hay 12 tareas", "Hay 13 tareas."),
        ("hay 12 tareas", "Hay tareas."),
        ("hay tareas", "Hay 12 tareas."),
        ("envía 12 y 24", "Envía 24 y 12."),
        ("12 12", "12"),
        ("valor -2.5", "Valor 2.5."),
        ("valor 1e3", "Valor 1e4."),
        ("abre SSH://host/ruta", "Abre HTTPS://host/ruta."),
        ("usa ABC123", "Usa ABC456."),
        ("no borres esto", "Borra esto."),
        ("borra esto", "No borres esto."),
        ("never delete this", "Delete this."),
        ("sans supprimer", "supprimer"),
        ("nicht löschen", "löschen"),
        ("senza cancellare", "cancellare"),
        ("não apagar", "apagar"),
        ("abre /tmp/source.txt", "Abre /tmp/target.txt."),
        ("visita https://example.com", "Visita https://other.com."),
        ("usa user_id", "Usa account_id."),
        ("usa getUser", "Usa getAdmin."),
        ("usa userID", "Usa accountID."),
        ("usa userID", "Usa userid."),
        ("cannot delete this", "can delete this"),
        ("I can’t delete this", "I can delete this"),
        ("usa el valor", "Usa new_value."),
        ("esto tiene varias instrucciones que deben mantenerse completas sin resumen", "Esto tiene instrucciones."),
        ("haz todo esto", ""),
        // La tolerancia de grafía no abre la puerta a cambiar el valor ni el sentido.
        ("necesito veinte unidades", "Necesito 30 unidades."),
        ("son 1000 euros", "Son 10.000 euros."),
        ("quedamos a las 10 30", "Quedamos a las 10:45."),
        ("no perdón no lo borres", "Bórralo."),
        ("va bien en el m1 pro", "Va bien en el M2 Pro."),
        ("lo probé en el iphone", "Lo probé en el iPad.")
    ])
    func rejectsProtectedChanges(raw: String, cleaned: String) {
        #expect(!CleanupGuard.preservesProtectedContent(cleaned: cleaned, raw: raw, vocabulary: []))
    }
}
