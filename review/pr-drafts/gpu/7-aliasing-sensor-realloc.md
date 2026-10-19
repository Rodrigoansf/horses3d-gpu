## Fix the aliasing sensor crash with a uniform polynomial order

`Sensor_aliasing` is meant to reallocate its scratch arrays only when the polynomial order changes, but `need_dealloc` stayed `.true.` when the shape matched, so the arrays were deallocated and never allocated again. The sensor then segfaulted on the second element, so `Shock sensor = aliasing error` could not be used with a uniform order.

No test uses this sensor. Legacy has the same bug (fixed in its own PR).
