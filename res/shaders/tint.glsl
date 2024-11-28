#version 330
in vec2 uv;
out vec4 fragment;
uniform sampler2D input_image;
uniform float mix_amount = 1.0;
uniform vec3 mix_color = vec3(1.0, 0.0, 0.0);;
void main()
{
    vec4 tmp = texture(input_image, vec2(uv.x, uv.y));
    fragment = mix(tmp, vec4(mix_color, 1.0) * tmp, mix_amount);
}
