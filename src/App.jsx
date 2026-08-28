import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import UserApp from './app-user/UserApp'
import MerchantApp from './app-merchant/MerchantApp'
import AdminApp from './app-admin/AdminApp'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/*" element={<UserApp />} />
        <Route path="/comercio/*" element={<MerchantApp />} />
        <Route path="/admin/*" element={<AdminApp />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  )
}
