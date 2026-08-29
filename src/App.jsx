import { BrowserRouter, Route, Routes } from 'react-router-dom'
import UserApp from './app-user/UserApp'
import MerchantApp from './app-merchant/MerchantApp'
import AdminApp from './app-admin/AdminApp'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        {/* React Router ordena por especificidad, no por orden de escritura: /comercio/* y
            /admin/* ganan sobre el comodín, que se queda con todo lo demás. */}
        <Route path="/comercio/*" element={<MerchantApp />} />
        <Route path="/admin/*" element={<AdminApp />} />
        <Route path="/*" element={<UserApp />} />
      </Routes>
    </BrowserRouter>
  )
}
