<?php

namespace App\Http\Resources;

use Illuminate\Http\Resources\Json\JsonResource;

class ProfileUserGeneralResource extends JsonResource
{
    /**
     * Transform the resource into an array.
     *
     * @param  \Illuminate\Http\Request  $request
     * @return array
     */
    public function toArray($request)
    {
        return [
            "id" => $this->resource->id,
            "name" => $this->resource->name,
            'surname' => $this->resource->surname,
            'email' => $this->resource->email,
            'phone' => $this->resource->phone,
            'birthdate' => $this->resource->birthdate ? $this->resource->birthdate->format("Y-m-d") : NULL,
            'website' => $this->resource->website,
            'address' => $this->resource->address,
            'avatar' => $this->resource->avatar ? env("APP_URL")."storage/".$this->resource->avatar : "https://cdn-icons-png.flaticon.com/512/3135/3135715.png",
            'fb' => $this->resource->fb,
            'tw' => $this->resource->tw,
            'inst' => $this->resource->inst,
            'linke' => $this->resource->linke,
        ];
    }
}
