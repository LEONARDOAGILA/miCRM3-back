<?php

namespace App\Http\Controllers\Concerns;

/**
 * Traduce el modelo de filtros de columna de ag-Grid a lo que entienden las
 * funciones de base.
 *
 * POR QUÉ EXISTE ESTO. Las pantallas que paginan en el servidor le dan a la
 * rejilla sólo las veinte filas de la página, así que si ag-Grid filtrara por
 * su cuenta buscaría dentro de veinte y parecería rota. La solución es que la
 * cabecera sólo recoja lo que el usuario pidió y el filtrado lo haga el
 * servidor sobre el total. Este traductor es la pieza del medio.
 *
 * Llega tal cual lo da la rejilla:
 *
 *     {"canton": {"filterType": "text", "type": "contains", "filter": "manta"}}
 *
 * y sale normalizado para la función:
 *
 *     {"canton": {"op": "contains", "valor": "manta"}}
 *
 * LA LISTA BLANCA LA PONE CADA PANTALLA, porque cada una filtra por lo suyo.
 * El nombre de la columna acaba dentro de una consulta, y de las dos formas
 * de evitar que eso sea un agujero —escapar o no aceptar nombres libres—
 * ésta es la que no depende de acordarse de escapar.
 */
trait FiltrosDeColumna
{
    /** Las operaciones de ag-Grid que las funciones saben aplicar. */
    private const OPERACIONES_FILTRO = [
        'texto'  => ['contains', 'notContains', 'equals', 'notEqual', 'startsWith', 'endsWith', 'blank', 'notBlank'],
        'numero' => ['equals', 'notEqual', 'lessThan', 'lessThanOrEqual', 'greaterThan', 'greaterThanOrEqual', 'inRange', 'blank', 'notBlank'],
    ];

    /**
     * @param string|null $crudo    El JSON que manda la rejilla.
     * @param array       $columnas Lista blanca: ['canton' => 'texto', 'id' => 'numero', …]
     *
     * Se tira en silencio todo lo que no cuadre: una columna que no está en la
     * lista, una operación que la base no sabe aplicar, o un filtro sin valor
     * cuando la operación lo necesita. Un filtro que no se entiende no es un
     * error de quien usa la pantalla; devolverle un 422 por algo que no ha
     * escrito él sería peor que no filtrar por eso.
     */
    private function filtrosDeColumna(?string $crudo, array $columnas): array
    {
        if (!$crudo) { return []; }

        $modelo = json_decode($crudo, true);
        if (!is_array($modelo)) { return []; }

        $limpio = [];
        foreach ($modelo as $columna => $f) {
            $tipo = $columnas[$columna] ?? null;
            if ($tipo === null || !is_array($f)) { continue; }

            // ag-Grid permite juntar dos condiciones con Y/O. Las pantallas lo
            // tienen desactivado, pero si llegara se coge la primera en vez de
            // filtrar por algo que no se pidió.
            if (isset($f['condition1'])) { $f = $f['condition1']; }

            $op = (string) ($f['type'] ?? 'contains');
            if (!in_array($op, self::OPERACIONES_FILTRO[$tipo] ?? [], true)) { continue; }

            $vacio = in_array($op, ['blank', 'notBlank'], true);
            $valor = $f['filter'] ?? null;
            if (!$vacio && ($valor === null || $valor === '')) { continue; }

            $limpio[$columna] = ['op' => $op];
            if (!$vacio) {
                $limpio[$columna]['valor'] = $tipo === 'numero' ? (string) (0 + $valor) : (string) $valor;
            }
            if ($op === 'inRange') {
                $hasta = $f['filterTo'] ?? null;
                if ($hasta === null || $hasta === '') { unset($limpio[$columna]); continue; }
                $limpio[$columna]['valor2'] = (string) (0 + $hasta);
            }
        }

        return $limpio;
    }
}
