# VETA Retro 1.0.0 · candidata 6 · compilación 205

Corrige dos problemas al cambiar de juego en el mismo proceso:

- Nintendo DS / DeSmuME: las ranuras y el renderer 3D dejan de conservar punteros a objetos destruidos al cerrar un juego y pueden inicializarse de nuevo.
- NES / FCEUmm: reinicia las opciones de RAM y batería del cartucho MMC3 y devuelve el bus abierto en lecturas de bancos sin memoria asignada, evitando accesos a un puntero nulo.

Las recetas públicas aplican ambos parches a los archivos originales fijados. Se conservan los formatos de ROM y partidas. El archivo de fuentes es completo y no requiere versiones anteriores. No incluye ROMs, portadas ni datos personales de la colección usada en pruebas.

Validación y alcance físico: consultar el informe de entrega. La prueba de arranque no acredita partidas completas ni compatibilidad universal. No es aprobación o envío a App Store. Los pendientes de distribución, arte y administración permanecen separados.
