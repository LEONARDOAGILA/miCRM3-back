<?php

namespace App\Http\Middleware;

use Illuminate\Foundation\Http\Middleware\PreventRequestForgery as Middleware;

class PreventRequestForgery extends Middleware
{
    /**
     * Las URIs que no pasan por la comprobación de falsificación.
     *
     * @var array<int, string>
     */
    protected $except = [
        //
    ];
}
